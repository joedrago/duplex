//! `/api/manifest` — the slim playback manifest. The server no longer probes
//! files: it reports only what it can know without decoding (path, size, the
//! raw URL, and the scan-derived sidecar list). Each client derives track and
//! codec facts from the file itself — mediabunny on web, libVLC on tvOS — so
//! there is no server-side playback decision to make here.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

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
    pub raw_url: String,
    pub sidecars: Vec<SidecarEntry>,
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

    let enc = vpath::encode(&vp);
    let raw_url = format!("/api/raw?path={enc}");

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
        raw_url,
        sidecars,
    })
    .into_response()
}
