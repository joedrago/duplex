//! On-demand WebVTT for sidecar files and embedded text subtitle streams.

use axum::body::Body;
use axum::extract::{Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use serde::Deserialize;

use crate::api::{vpath, AppState};
use crate::ffmpeg;
use crate::library::Node;

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/subs", get(subs))
}

#[derive(Debug, Deserialize)]
pub struct SubsQuery {
    pub path: String,
    /// Either `sidecar:<n>` (index into the file's sidecar list) or `embedded:<index>`.
    pub track: String,
}

pub async fn subs(
    State(state): State<AppState>,
    Query(q): Query<SubsQuery>,
) -> axum::response::Response {
    let Some(vp) = vpath::normalize(&q.path) else {
        return (StatusCode::BAD_REQUEST, "invalid path").into_response();
    };
    let tree = state.library.snapshot();
    let Some(Node::File(file)) = tree.lookup(&vp) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let file = file.clone();
    drop(tree);

    let (kind, value) = match q.track.split_once(':') {
        Some(p) => p,
        None => return (StatusCode::BAD_REQUEST, "bad track").into_response(),
    };
    match kind {
        "sidecar" => {
            let Ok(i) = value.parse::<usize>() else {
                return StatusCode::BAD_REQUEST.into_response();
            };
            let Some(sc) = file.sidecars.get(i) else {
                return StatusCode::NOT_FOUND.into_response();
            };
            if sc.format == "vtt" {
                match tokio::fs::read(&sc.abs_path).await {
                    Ok(bytes) => (
                        StatusCode::OK,
                        [(header::CONTENT_TYPE, "text/vtt; charset=utf-8")],
                        bytes,
                    )
                        .into_response(),
                    Err(e) => {
                        tracing::warn!("read sidecar {}: {}", sc.abs_path.display(), e);
                        StatusCode::INTERNAL_SERVER_ERROR.into_response()
                    }
                }
            } else {
                let stream = ffmpeg::sidecar_to_vtt(&state.cfg.ffmpeg, &sc.abs_path, &sc.format);
                (
                    StatusCode::OK,
                    [(header::CONTENT_TYPE, "text/vtt; charset=utf-8")],
                    Body::from_stream(stream),
                )
                    .into_response()
            }
        }
        "embedded" => {
            let Ok(idx) = value.parse::<u32>() else {
                return StatusCode::BAD_REQUEST.into_response();
            };
            let stream = ffmpeg::embedded_sub_to_vtt(&state.cfg.ffmpeg, &file.abs_path, idx);
            (
                StatusCode::OK,
                [(header::CONTENT_TYPE, "text/vtt; charset=utf-8")],
                Body::from_stream(stream),
            )
                .into_response()
        }
        _ => (StatusCode::BAD_REQUEST, "bad track kind").into_response(),
    }
}
