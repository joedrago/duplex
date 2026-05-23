//! Embedded static assets (web client). Served from `/`.

use axum::body::Body;
use axum::http::{header, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use rust_embed::RustEmbed;

use crate::api::AppState;

#[derive(RustEmbed)]
#[folder = "$CARGO_MANIFEST_DIR/web"]
struct Assets;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/", get(index))
        .route("/{*path}", get(static_or_index))
}

async fn index() -> Response {
    serve("index.html")
}

async fn static_or_index(uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    if path.is_empty() {
        return serve("index.html");
    }
    if Assets::get(path).is_some() {
        serve(path)
    } else {
        // SPA-style hash routing: anything we don't have, fall back to index.html.
        serve("index.html")
    }
}

fn serve(name: &str) -> Response {
    match Assets::get(name) {
        Some(file) => {
            let mime = file.metadata.mimetype();
            (
                StatusCode::OK,
                [(header::CONTENT_TYPE, mime.to_string())],
                Body::from(file.data.into_owned()),
            )
                .into_response()
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
