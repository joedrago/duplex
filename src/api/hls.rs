//! HLS endpoints: a single combined-rendition fragmented MP4 stream per
//! `(file, audio_idx, transcode)` triple, served from the StreamCache.
//!
//! URL shape:
//!   /api/play/<vpath>/master.m3u8                  → master with one STREAM-INF
//!   /api/play/<vpath>/index.m3u8                   → media playlist
//!   /api/play/<vpath>/init.mp4                     → ftyp + moov
//!   /api/play/<vpath>/<N>.m4s                      → moof + mdat fragment
//!
//! Audio track selection is via `?audio=<index>`. If absent, the first
//! audio stream is used; if transcode is forced via probe, that's
//! decided by the capability matrix at handler entry.

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use serde::Deserialize;

use crate::api::{vpath, AppState};
use crate::capability::{self, Decision};
use crate::library::Node;
use crate::probe::Probe;

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/play/{*tail}", get(dispatch))
}

#[derive(Deserialize, Default)]
struct PlayQuery {
    audio: Option<u32>,
}

async fn dispatch(
    State(state): State<AppState>,
    Path(tail): Path<String>,
    Query(q): Query<PlayQuery>,
) -> axum::response::Response {
    let Some((vpath_raw, sub)) = split_vpath_and_sub(&tail) else {
        return (StatusCode::BAD_REQUEST, "bad path").into_response();
    };
    let Some(vp) = vpath::normalize(vpath_raw) else {
        return (StatusCode::BAD_REQUEST, "invalid path").into_response();
    };
    let tree = state.library.snapshot();
    let Some(Node::File(f)) = tree.lookup(&vp) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let file = f.clone();
    drop(tree);

    let probe = match state.probe.get_or_probe(&file.abs_path, file.size, file.mtime).await {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("probe failed: {e:#}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let caps = capability::default_caps();
    let decision = capability::decide(&probe, &caps);
    if matches!(decision, Decision::DirectPlay | Decision::Unsupported) {
        return (StatusCode::BAD_REQUEST, "file is not HLS-eligible").into_response();
    }

    let audio_idx = match resolve_audio_idx(&probe, q.audio) {
        Some(i) => i,
        None => return (StatusCode::BAD_REQUEST, "no audio stream").into_response(),
    };
    let transcode = audio_needs_transcode(&probe, audio_idx, decision);

    if sub == ["master.m3u8"] {
        return master_playlist(&vp, &probe, decision, audio_idx).into_response();
    }

    let kf = match state
        .keyframes
        .get_or_extract(&file.abs_path, file.size, file.mtime, probe.duration_secs().unwrap_or(0.0))
        .await
    {
        Ok(k) => k,
        Err(e) => {
            tracing::warn!("keyframe extraction failed: {e:#}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };

    if sub == ["index.m3u8"] {
        return media_playlist(&vp, &kf, audio_idx).into_response();
    }

    let stream = state
        .streams
        .get_or_create(
            file.abs_path.clone(),
            crate::probe::Key::new(&file.abs_path, file.mtime, file.size),
            kf.clone(),
            audio_idx,
            transcode,
        )
        .await;

    match sub.as_slice() {
        ["init.mp4"] => match stream.init_segment().await {
            Ok(bytes) => (
                StatusCode::OK,
                [(header::CONTENT_TYPE, "video/mp4")],
                bytes,
            )
                .into_response(),
            Err(e) => {
                tracing::warn!("init segment failed: {e:#}");
                StatusCode::INTERNAL_SERVER_ERROR.into_response()
            }
        },
        [seg] => match parse_seg_index(seg) {
            Some(n) => match stream.segment(n).await {
                Ok(bytes) => (
                    StatusCode::OK,
                    [(header::CONTENT_TYPE, "video/mp4")],
                    bytes,
                )
                    .into_response(),
                Err(e) => {
                    tracing::warn!("segment {n} failed: {e:#}");
                    StatusCode::INTERNAL_SERVER_ERROR.into_response()
                }
            },
            None => StatusCode::BAD_REQUEST.into_response(),
        },
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

fn split_vpath_and_sub(tail: &str) -> Option<(&str, Vec<&str>)> {
    for suffix in &["/master.m3u8", "/index.m3u8", "/init.mp4"] {
        if let Some(s) = tail.strip_suffix(suffix) {
            return Some((s, vec![&suffix[1..]]));
        }
    }
    let idx = tail.rfind('/')?;
    let (left, right) = tail.split_at(idx);
    let right = &right[1..];
    if right.ends_with(".m4s") {
        Some((left, vec![right]))
    } else {
        None
    }
}

fn resolve_audio_idx(probe: &Probe, requested: Option<u32>) -> Option<u32> {
    if let Some(idx) = requested {
        if probe.audio_streams().any(|s| s.index == idx) {
            return Some(idx);
        }
        return None;
    }
    probe.audio_streams().next().map(|s| s.index)
}

fn audio_needs_transcode(probe: &Probe, audio_idx: u32, decision: Decision) -> bool {
    if matches!(decision, Decision::HlsAudioTranscode) {
        return true;
    }
    let caps = capability::default_caps();
    let Some(stream) = probe.streams.iter().find(|s| s.index == audio_idx) else {
        return true;
    };
    !stream
        .codec_name
        .as_deref()
        .map(|c| caps.audio_codecs.contains(c))
        .unwrap_or(false)
}

fn master_playlist(
    vpath: &str,
    probe: &Probe,
    decision: Decision,
    audio_idx: u32,
) -> impl IntoResponse {
    let enc = vpath::encode(vpath);
    let video_codec = probe.video_codec().unwrap_or("avc1");
    let bandwidth = bandwidth_estimate(probe, decision);
    let res = match (
        probe.video_stream().and_then(|v| v.width),
        probe.video_stream().and_then(|v| v.height),
    ) {
        (Some(w), Some(h)) => format!(",RESOLUTION={w}x{h}"),
        _ => String::new(),
    };
    let codec_attr = codec_string_for(video_codec);
    let mut s = String::new();
    s.push_str("#EXTM3U\n");
    s.push_str("#EXT-X-VERSION:7\n");
    s.push_str("#EXT-X-INDEPENDENT-SEGMENTS\n");
    s.push_str(&format!(
        "#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},CODECS=\"{codec_attr}\"{res}\n"
    ));
    s.push_str(&format!("/api/play/{enc}/index.m3u8?audio={audio_idx}\n"));
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")],
        s,
    )
}

fn media_playlist(vpath: &str, kf: &crate::probe::keyframes::Keyframes, audio_idx: u32) -> impl IntoResponse {
    let enc = vpath::encode(vpath);
    let segments = kf.segments();
    let target = kf.target_duration();
    let q = format!("?audio={audio_idx}");

    let mut s = String::new();
    s.push_str("#EXTM3U\n");
    s.push_str("#EXT-X-VERSION:7\n");
    s.push_str(&format!("#EXT-X-TARGETDURATION:{target}\n"));
    s.push_str("#EXT-X-PLAYLIST-TYPE:VOD\n");
    s.push_str("#EXT-X-MEDIA-SEQUENCE:0\n");
    s.push_str(&format!("#EXT-X-MAP:URI=\"/api/play/{enc}/init.mp4{q}\"\n"));
    for (i, (_start, dur)) in segments.iter().enumerate() {
        s.push_str(&format!("#EXTINF:{:.3},\n", dur));
        s.push_str(&format!("/api/play/{enc}/{i}.m4s{q}\n"));
    }
    s.push_str("#EXT-X-ENDLIST\n");

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")],
        s,
    )
}

fn codec_string_for(video_codec: &str) -> String {
    let v = match video_codec {
        "h264" => "avc1.4d401f",
        "hevc" => "hvc1.1.6.L120.90",
        other => other,
    };
    format!("{v},mp4a.40.2")
}

fn bandwidth_estimate(probe: &Probe, _decision: Decision) -> u64 {
    probe
        .format
        .bit_rate
        .as_deref()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(5_000_000)
}

fn parse_seg_index(seg: &str) -> Option<usize> {
    seg.strip_suffix(".m4s")?.parse().ok()
}
