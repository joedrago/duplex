//! Range-aware passthrough of original file bytes. The only playback
//! endpoint in the slim server — the client-side WebCodecs player demuxes
//! everything it fetches here.

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
    Router::new().route("/api/raw", get(raw))
}

#[derive(Debug, Deserialize)]
pub struct RawQuery {
    pub path: String,
}

pub async fn raw(
    State(state): State<AppState>,
    Query(q): Query<RawQuery>,
    req: Request<Body>,
) -> impl IntoResponse {
    let Some(vp) = vpath::normalize(&q.path) else {
        return (StatusCode::BAD_REQUEST, "invalid path").into_response();
    };
    let tree = state.library.snapshot();
    let Some(Node::File(f)) = tree.lookup(&vp) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let abs = f.abs_path.clone();
    drop(tree);

    // tower-http's ServeFile handles Range, If-Range, 206/416 correctly.
    let service = ServeFile::new(&abs);
    match service.oneshot(req).await {
        Ok(res) => res.into_response(),
        Err(e) => {
            tracing::error!("serve {} failed: {e}", abs.display());
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}
