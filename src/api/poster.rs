//! `/api/poster` — serves the sidecar poster image (a sibling `.jpg`/`.jpeg`
//! sharing a video's stem), if one was discovered during the scan. Mirrors
//! `raw.rs`: tower-http's `ServeFile` handles Range / conditional requests and
//! infers the `image/jpeg` content type from the extension. 404 when the video
//! has no poster.

use axum::body::Body;
use axum::extract::{Query, Request, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use serde::Deserialize;
use tower::ServiceExt;
use tower_http::services::ServeFile;

use crate::api::{vpath, AppState};
use crate::library::Node;

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/poster", get(poster))
}

#[derive(Debug, Deserialize)]
pub struct PosterQuery {
    /// Virtual path of the *video* whose poster we want.
    pub path: String,
}

pub async fn poster(
    State(state): State<AppState>,
    Query(q): Query<PosterQuery>,
    req: Request<Body>,
) -> impl IntoResponse {
    let Some(vp) = vpath::normalize(&q.path) else {
        return (StatusCode::BAD_REQUEST, "invalid path").into_response();
    };
    let tree = state.library.snapshot();
    let Some(Node::File(f)) = tree.lookup(&vp) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(abs) = f.poster.clone() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    drop(tree);

    let service = ServeFile::new(&abs);
    match service.oneshot(req).await {
        Ok(res) => res.into_response(),
        Err(e) => {
            tracing::error!("serve poster {} failed: {e}", abs.display());
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}
