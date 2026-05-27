//! `/api/sidecar?path=<vpath>&index=<n>` — stream the raw bytes of one of a
//! file's sidecar subtitle files. The client parses VTT/SRT/ASS in JS.
//!
//! Sidecars aren't addressable via `/api/raw` because `attach_sidecars` strips
//! subtitle file nodes from the library tree (they ride on their video file in
//! the manifest instead of standing alone in browse listings).

use axum::body::Body;
use axum::extract::{Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use serde::Deserialize;

use crate::api::{vpath, AppState};
use crate::library::Node;

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/sidecar", get(sidecar))
}

#[derive(Debug, Deserialize)]
pub struct SidecarQuery {
    pub path: String,
    pub index: usize,
}

pub async fn sidecar(
    State(state): State<AppState>,
    Query(q): Query<SidecarQuery>,
) -> axum::response::Response {
    let Some(vp) = vpath::normalize(&q.path) else {
        return (StatusCode::BAD_REQUEST, "invalid path").into_response();
    };
    let tree = state.library.snapshot();
    let Some(Node::File(file)) = tree.lookup(&vp) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(sc) = file.sidecars.get(q.index).cloned() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    drop(tree);

    match tokio::fs::read(&sc.abs_path).await {
        Ok(bytes) => {
            let mime = match sc.format.as_str() {
                "vtt" => "text/vtt; charset=utf-8",
                "srt" => "application/x-subrip; charset=utf-8",
                "ass" | "ssa" => "text/x-ssa; charset=utf-8",
                _ => "text/plain; charset=utf-8",
            };
            (
                StatusCode::OK,
                [(header::CONTENT_TYPE, mime)],
                Body::from(bytes),
            )
                .into_response()
        }
        Err(e) => {
            tracing::warn!("read sidecar {}: {}", sc.abs_path.display(), e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}
