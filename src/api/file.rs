use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::{vpath, AppState};
use crate::capability::{self, Decision};
use crate::library::{Node, Sidecar};
use crate::probe::Probe;

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/file", get(file))
}

#[derive(Debug, Deserialize)]
pub struct FileQuery {
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct FileResponse {
    pub path: String,
    pub size: u64,
    pub ext: Option<String>,
    pub decision: String,
    pub probe: Option<Probe>,
    pub sidecars: Vec<Sidecar>,
    pub embedded_subs: Vec<EmbeddedSub>,
    pub audio_tracks: Vec<AudioTrack>,
    pub urls: Urls,
}

#[derive(Debug, Serialize)]
pub struct EmbeddedSub {
    pub index: u32,
    pub codec: Option<String>,
    pub language: Option<String>,
    pub format: SubFormat,
}

#[derive(Debug, Serialize)]
pub struct AudioTrack {
    pub index: u32,
    pub codec: Option<String>,
    pub language: Option<String>,
    pub channels: Option<u32>,
    pub channel_layout: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SubFormat {
    Text,
    Image,
}

#[derive(Debug, Serialize)]
pub struct Urls {
    pub raw: Option<String>,
    pub master: Option<String>,
}

pub async fn file(
    State(state): State<AppState>,
    Query(q): Query<FileQuery>,
) -> impl IntoResponse {
    let Some(vp) = vpath::normalize(&q.path) else {
        return (axum::http::StatusCode::BAD_REQUEST, "invalid path").into_response();
    };
    let tree = state.library.snapshot();
    let Some(node) = tree.lookup(&vp) else {
        return axum::http::StatusCode::NOT_FOUND.into_response();
    };
    let f = match node {
        Node::File(f) => f.clone(),
        Node::Dir(_) => {
            return (axum::http::StatusCode::BAD_REQUEST, "path is a directory").into_response();
        }
    };

    let probe = match state.probe.get_or_probe(&f.abs_path, f.size, f.mtime).await {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(path = %f.abs_path.display(), "probe failed: {e:#}");
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                format!("probe failed: {e}"),
            )
                .into_response();
        }
    };

    let caps = capability::default_caps();
    let decision = capability::decide(&probe, &caps);

    let mut embedded = Vec::new();
    for s in probe.subtitle_streams() {
        let codec = s.codec_name.clone();
        let language = s.tags.as_ref().and_then(|t| t.get("language").cloned());
        let format = match codec.as_deref() {
            Some("subrip" | "ass" | "ssa" | "mov_text" | "webvtt") => SubFormat::Text,
            _ => SubFormat::Image,
        };
        embedded.push(EmbeddedSub {
            index: s.index,
            codec,
            language,
            format,
        });
    }

    let audio_tracks = probe
        .audio_streams()
        .map(|s| AudioTrack {
            index: s.index,
            codec: s.codec_name.clone(),
            language: s.tags.as_ref().and_then(|t| t.get("language").cloned()),
            channels: s.channels,
            channel_layout: s.channel_layout.clone(),
        })
        .collect();

    let enc = vpath::encode(&vp);
    let raw_url = matches!(decision, Decision::DirectPlay).then(|| format!("/api/raw?path={enc}"));
    let master_url = (!matches!(decision, Decision::DirectPlay | Decision::Unsupported))
        .then(|| format!("/api/play/{enc}/master.m3u8"));

    Json(FileResponse {
        path: vp,
        size: f.size,
        ext: f.ext.clone(),
        decision: decision.label(),
        probe: Some((*probe).clone()),
        sidecars: f.sidecars.clone(),
        embedded_subs: embedded,
        audio_tracks,
        urls: Urls { raw: raw_url, master: master_url },
    })
    .into_response()
}
