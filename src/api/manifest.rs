//! `/api/manifest` — the slim playback manifest consumed by the new client-side
//! player. Replaces `/api/file` in spirit: just the facts about what's in the
//! file (tracks, codecs, sidecars) without any server-side playback decision.
//! The client does its own `VideoDecoder.isConfigSupported` check and decides
//! what to do.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::codec_string::{audio_codec_string, video_codec_string};
use crate::api::{vpath, AppState};
use crate::library::Node;

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/manifest", get(manifest))
}

#[derive(Debug, Deserialize)]
pub struct ManifestQuery {
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct ManifestResponse {
    pub path: String,
    pub size: u64,
    pub duration: Option<f64>,
    pub container: String,
    pub raw_url: String,
    pub video_tracks: Vec<VideoTrack>,
    pub audio_tracks: Vec<AudioTrack>,
    pub subtitle_tracks: Vec<SubtitleTrack>,
    pub sidecars: Vec<SidecarEntry>,
}

#[derive(Debug, Serialize)]
pub struct VideoTrack {
    pub index: u32,
    pub codec: Option<String>,
    pub codec_string: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub profile: Option<String>,
    pub level: Option<i32>,
    pub pix_fmt: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AudioTrack {
    pub index: u32,
    pub codec: Option<String>,
    pub codec_string: Option<String>,
    pub channels: Option<u32>,
    pub channel_layout: Option<String>,
    pub sample_rate: Option<u32>,
    pub language: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SubtitleTrack {
    pub index: u32,
    pub codec: Option<String>,
    pub language: Option<String>,
    pub format: SubFormat,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SubFormat {
    Text,
    Image,
}

#[derive(Debug, Serialize)]
pub struct SidecarEntry {
    pub index: usize,
    pub format: String,
    pub language: Option<String>,
    pub url: String,
}

pub async fn manifest(
    State(state): State<AppState>,
    Query(q): Query<ManifestQuery>,
) -> impl IntoResponse {
    let Some(vp) = vpath::normalize(&q.path) else {
        return (StatusCode::BAD_REQUEST, "invalid path").into_response();
    };
    let tree = state.library.snapshot();
    let Some(node) = tree.lookup(&vp) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let f = match node {
        Node::File(f) => f.clone(),
        Node::Dir(_) => {
            return (StatusCode::BAD_REQUEST, "path is a directory").into_response();
        }
    };
    drop(tree);

    let probe = match state.probe.get_or_probe(&f.abs_path, f.size, f.mtime).await {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(path = %f.abs_path.display(), "probe failed: {e:#}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("probe failed: {e}"),
            )
                .into_response();
        }
    };

    let enc = vpath::encode(&vp);
    let raw_url = format!("/api/raw?path={enc}");

    let video_tracks: Vec<VideoTrack> = probe
        .streams
        .iter()
        .filter(|s| s.codec_type == "video")
        .map(|s| VideoTrack {
            index: s.index,
            codec: s.codec_name.clone(),
            codec_string: video_codec_string(s),
            width: s.width,
            height: s.height,
            profile: s.profile.clone(),
            level: s.level,
            pix_fmt: s.pix_fmt.clone(),
        })
        .collect();

    let audio_tracks: Vec<AudioTrack> = probe
        .audio_streams()
        .map(|s| AudioTrack {
            index: s.index,
            codec: s.codec_name.clone(),
            codec_string: audio_codec_string(s),
            channels: s.channels,
            channel_layout: s.channel_layout.clone(),
            sample_rate: s.sample_rate.as_deref().and_then(|s| s.parse().ok()),
            language: s.tags.as_ref().and_then(|t| t.get("language").cloned()),
        })
        .collect();

    let subtitle_tracks: Vec<SubtitleTrack> = probe
        .subtitle_streams()
        .map(|s| {
            let codec = s.codec_name.clone();
            let format = match codec.as_deref() {
                Some("subrip" | "ass" | "ssa" | "mov_text" | "webvtt") => SubFormat::Text,
                _ => SubFormat::Image,
            };
            SubtitleTrack {
                index: s.index,
                codec,
                language: s.tags.as_ref().and_then(|t| t.get("language").cloned()),
                format,
            }
        })
        .collect();

    let sidecars: Vec<SidecarEntry> = f
        .sidecars
        .iter()
        .enumerate()
        .map(|(i, sc)| SidecarEntry {
            index: i,
            format: sc.format.clone(),
            language: sc.language.clone(),
            url: format!("/api/sidecar?path={enc}&index={i}"),
        })
        .collect();

    Json(ManifestResponse {
        path: vp,
        size: f.size,
        duration: probe.duration_secs(),
        container: probe.format.format_name.clone(),
        raw_url,
        video_tracks,
        audio_tracks,
        subtitle_tracks,
        sidecars,
    })
    .into_response()
}
