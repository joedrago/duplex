//! HLS endpoints: master playlist, video/audio media playlists, init segment,
//! and per-segment fMP4 streamed from ffmpeg stdout.

use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;

use crate::api::{vpath, AppState};
use crate::capability::{self, Decision};
use crate::ffmpeg;
use crate::library::Node;
use crate::probe::Probe;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/play/{*tail}", get(dispatch))
}

/// Hand-rolled dispatcher: split the wildcard tail into the virtual file path
/// and the HLS resource (master playlist / video|audio media playlist / init
/// segment / numbered segment), look up the file, dispatch accordingly.
async fn dispatch(
    State(state): State<AppState>,
    Path(tail): Path<String>,
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

    match sub.as_slice() {
        ["master.m3u8"] => master_playlist(&vp, &probe, decision).into_response(),
        ["v", "index.m3u8"] => video_playlist(&state, &file, &probe).await,
        ["v", "init.mp4"] => init_segment_video(&state, &file, &probe).await,
        ["v", seg] => segment_video(&state, &file, &probe, seg).await,
        ["a", idx, "index.m3u8"] => audio_playlist(&state, &file, &probe, idx, decision).await,
        ["a", idx, "init.mp4"] => init_segment_audio(&state, &file, &probe, idx, decision).await,
        ["a", idx, seg] => segment_audio(&state, &file, &probe, idx, seg, decision).await,
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

/// Split a wildcard tail into (virtual file path, sub-resource components).
/// The sub-resource is one of: ["master.m3u8"], ["v","index.m3u8"], ["v","init.mp4"],
/// ["v","<n>.m4s"], ["a","<idx>","index.m3u8"], etc.
fn split_vpath_and_sub(tail: &str) -> Option<(&str, Vec<&str>)> {
    // master.m3u8
    if let Some(stripped) = tail.strip_suffix("/master.m3u8") {
        return Some((stripped, vec!["master.m3u8"]));
    }
    // v/* (init, index, <n>.m4s)
    for suffix in &["/v/init.mp4", "/v/index.m3u8"] {
        if let Some(s) = tail.strip_suffix(suffix) {
            let last = &suffix[1..]; // strip leading '/'
            return Some((s, last.split('/').collect()));
        }
    }
    if let Some(idx) = tail.rfind("/v/") {
        let (left, right) = tail.split_at(idx);
        let right = &right[3..]; // skip "/v/"
        return Some((left, vec!["v", right]));
    }
    // a/<idx>/...
    if let Some(idx) = tail.rfind("/a/") {
        let (left, right) = tail.split_at(idx);
        let right = &right[3..]; // skip "/a/"
        let mut parts: Vec<&str> = right.splitn(2, '/').collect();
        if parts.len() != 2 {
            return None;
        }
        let audio_idx = parts.remove(0);
        let last = parts.remove(0);
        return Some((left, vec!["a", audio_idx, last]));
    }
    None
}

fn master_playlist(vpath: &str, probe: &Probe, decision: Decision) -> impl IntoResponse {
    let enc = vpath::encode(vpath);
    let mut s = String::new();
    s.push_str("#EXTM3U\n");
    s.push_str("#EXT-X-VERSION:7\n");
    s.push_str("#EXT-X-INDEPENDENT-SEGMENTS\n");

    // Audio renditions: one group, one entry per audio stream.
    let audios: Vec<_> = probe.audio_streams().collect();
    for (i, a) in audios.iter().enumerate() {
        let lang = a
            .tags
            .as_ref()
            .and_then(|t| t.get("language"))
            .cloned()
            .unwrap_or_else(|| "und".to_string());
        let title = a
            .tags
            .as_ref()
            .and_then(|t| t.get("title"))
            .cloned()
            .unwrap_or_else(|| {
                a.codec_name.clone().unwrap_or_else(|| format!("track {}", a.index))
            });
        let default = if i == 0 { "YES" } else { "NO" };
        s.push_str(&format!(
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"{title}\",LANGUAGE=\"{lang}\",DEFAULT={default},AUTOSELECT=YES,URI=\"/api/play/{enc}/a/{idx}/index.m3u8\"\n",
            title = title.replace('"', "'"),
            idx = a.index,
        ));
    }

    let video_codec = probe.video_codec().unwrap_or("avc1");
    let bandwidth = bandwidth_estimate(probe, decision);
    let res = match (probe.video_stream().and_then(|v| v.width), probe.video_stream().and_then(|v| v.height)) {
        (Some(w), Some(h)) => format!(",RESOLUTION={w}x{h}"),
        _ => String::new(),
    };
    let codec_attr = codec_string_for(video_codec, decision);
    s.push_str(&format!(
        "#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},CODECS=\"{codec_attr}\"{res},AUDIO=\"aud\"\n",
    ));
    s.push_str(&format!("/api/play/{enc}/v/index.m3u8\n"));

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")],
        s,
    )
}

fn codec_string_for(video_codec: &str, decision: Decision) -> String {
    // Best-effort CODECS string. hls.js + Safari are lenient if this is loose,
    // but it must include valid AAC if any audio is transcoded.
    let v = match video_codec {
        "h264" => "avc1.4d401f", // baseline-ish; OK if probe doesn't give us a profile
        "hevc" => "hvc1.1.6.L120.90",
        other => other,
    };
    let a = match decision {
        Decision::HlsAudioTranscode => "mp4a.40.2",
        _ => "mp4a.40.2",
    };
    format!("{v},{a}")
}

fn bandwidth_estimate(probe: &Probe, _decision: Decision) -> u64 {
    probe
        .format
        .bit_rate
        .as_deref()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(5_000_000)
}

async fn video_playlist(
    state: &AppState,
    file: &crate::library::File,
    probe: &Probe,
) -> axum::response::Response {
    let duration = probe.duration_secs().unwrap_or(0.0);
    let kf = match state
        .keyframes
        .get_or_extract(&file.abs_path, file.size, file.mtime, duration)
        .await
    {
        Ok(k) => k,
        Err(e) => {
            tracing::warn!("keyframe extraction failed: {e:#}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let segments = kf.segments();
    let target = kf.target_duration();

    let Some(vp) = state.library.vpath_for(&file.abs_path) else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let enc = vpath::encode(&vp);

    let mut s = String::new();
    s.push_str("#EXTM3U\n");
    s.push_str("#EXT-X-VERSION:7\n");
    s.push_str(&format!("#EXT-X-TARGETDURATION:{target}\n"));
    s.push_str("#EXT-X-PLAYLIST-TYPE:VOD\n");
    s.push_str("#EXT-X-MEDIA-SEQUENCE:0\n");
    s.push_str(&format!("#EXT-X-MAP:URI=\"/api/play/{enc}/v/init.mp4\"\n"));
    for (i, (_start, dur)) in segments.iter().enumerate() {
        s.push_str(&format!("#EXTINF:{:.3},\n", dur));
        s.push_str(&format!("/api/play/{enc}/v/{i}.m4s\n"));
    }
    s.push_str("#EXT-X-ENDLIST\n");

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")],
        s,
    )
        .into_response()
}

async fn audio_playlist(
    state: &AppState,
    file: &crate::library::File,
    probe: &Probe,
    idx_str: &str,
    decision: Decision,
) -> axum::response::Response {
    let Ok(idx) = idx_str.parse::<u32>() else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    if probe.audio_streams().all(|s| s.index != idx) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let duration = probe.duration_secs().unwrap_or(0.0);
    let kf = match state
        .keyframes
        .get_or_extract(&file.abs_path, file.size, file.mtime, duration)
        .await
    {
        Ok(k) => k,
        Err(e) => {
            tracing::warn!("keyframe extraction failed: {e:#}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let segments = kf.segments();
    let target = kf.target_duration();
    let _ = decision;

    let Some(vp) = state.library.vpath_for(&file.abs_path) else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let enc = vpath::encode(&vp);

    let mut s = String::new();
    s.push_str("#EXTM3U\n");
    s.push_str("#EXT-X-VERSION:7\n");
    s.push_str(&format!("#EXT-X-TARGETDURATION:{target}\n"));
    s.push_str("#EXT-X-PLAYLIST-TYPE:VOD\n");
    s.push_str("#EXT-X-MEDIA-SEQUENCE:0\n");
    s.push_str(&format!(
        "#EXT-X-MAP:URI=\"/api/play/{enc}/a/{idx}/init.mp4\"\n"
    ));
    for (i, (_start, dur)) in segments.iter().enumerate() {
        s.push_str(&format!("#EXTINF:{:.3},\n", dur));
        s.push_str(&format!("/api/play/{enc}/a/{idx}/{i}.m4s\n"));
    }
    s.push_str("#EXT-X-ENDLIST\n");

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")],
        s,
    )
        .into_response()
}

async fn init_segment_video(
    state: &AppState,
    file: &crate::library::File,
    _probe: &Probe,
) -> axum::response::Response {
    match ffmpeg::init_segment_video(&state.cfg.ffmpeg, &file.abs_path).await {
        Ok(bytes) => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "video/mp4")],
            bytes,
        )
            .into_response(),
        Err(e) => {
            tracing::warn!("init video failed: {e:#}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn init_segment_audio(
    state: &AppState,
    file: &crate::library::File,
    probe: &Probe,
    idx_str: &str,
    decision: Decision,
) -> axum::response::Response {
    let Ok(idx) = idx_str.parse::<u32>() else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let Some(stream) = probe.streams.iter().find(|s| s.index == idx) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let transcode = needs_audio_transcode(stream, decision);
    match ffmpeg::init_segment_audio(&state.cfg.ffmpeg, &file.abs_path, idx, transcode).await {
        Ok(bytes) => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "video/mp4")],
            bytes,
        )
            .into_response(),
        Err(e) => {
            tracing::warn!("init audio failed: {e:#}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn segment_video(
    state: &AppState,
    file: &crate::library::File,
    probe: &Probe,
    seg: &str,
) -> axum::response::Response {
    let Some(n) = parse_seg_index(seg) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let duration = probe.duration_secs().unwrap_or(0.0);
    let kf = match state
        .keyframes
        .get_or_extract(&file.abs_path, file.size, file.mtime, duration)
        .await
    {
        Ok(k) => k,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let segments = kf.segments();
    let Some(&(start, dur)) = segments.get(n) else {
        return StatusCode::NOT_FOUND.into_response();
    };

    match ffmpeg::segment_video(&state.cfg.ffmpeg, &file.abs_path, start, dur).await {
        Ok(bytes) => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "video/mp4")],
            bytes,
        )
            .into_response(),
        Err(e) => {
            tracing::warn!("segment video failed: {e:#}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn segment_audio(
    state: &AppState,
    file: &crate::library::File,
    probe: &Probe,
    idx_str: &str,
    seg: &str,
    decision: Decision,
) -> axum::response::Response {
    let Ok(idx) = idx_str.parse::<u32>() else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let Some(stream) = probe.streams.iter().find(|s| s.index == idx) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(n) = parse_seg_index(seg) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let duration = probe.duration_secs().unwrap_or(0.0);
    let kf = match state
        .keyframes
        .get_or_extract(&file.abs_path, file.size, file.mtime, duration)
        .await
    {
        Ok(k) => k,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let segments = kf.segments();
    let Some(&(start, dur)) = segments.get(n) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let transcode = needs_audio_transcode(stream, decision);
    match ffmpeg::segment_audio(&state.cfg.ffmpeg, &file.abs_path, idx, start, dur, transcode).await {
        Ok(bytes) => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "video/mp4")],
            bytes,
        )
            .into_response(),
        Err(e) => {
            tracing::warn!("segment audio failed: {e:#}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

fn needs_audio_transcode(stream: &crate::probe::Stream, decision: Decision) -> bool {
    if matches!(decision, Decision::HlsAudioTranscode) {
        return true;
    }
    let caps = capability::default_caps();
    !stream
        .codec_name
        .as_deref()
        .map(|c| caps.audio_codecs.contains(c))
        .unwrap_or(false)
}

fn parse_seg_index(seg: &str) -> Option<usize> {
    let stem = seg.strip_suffix(".m4s")?;
    stem.parse().ok()
}
