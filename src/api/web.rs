//! Embedded static assets (web client). Served from `/`.

use axum::body::Body;
use axum::extract::State;
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

async fn index(State(state): State<AppState>) -> Response {
    serve_index(&state)
}

async fn static_or_index(State(state): State<AppState>, uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    if path.is_empty() {
        return serve_index(&state);
    }
    if Assets::get(path).is_some() {
        serve(path)
    } else {
        // SPA-style hash routing: anything we don't have, fall back to index.html.
        serve_index(&state)
    }
}

fn serve_index(state: &AppState) -> Response {
    let Some(file) = Assets::get("index.html") else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let html = match std::str::from_utf8(&file.data) {
        Ok(s) => inject_config(s, state),
        // index.html is authored by us; if it isn't UTF-8, fall back to the raw
        // bytes rather than 500ing — but in practice this never fires.
        Err(_) => return serve("index.html"),
    };
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        Body::from(html),
    )
        .into_response()
}

/// Inject `<script>window.__DUPLEX_CONFIG__ = {...}</script>` before the first
/// `<script` tag in the document so the client knows the server's debug flags
/// before any other JS runs.
fn inject_config(html: &str, state: &AppState) -> String {
    let cfg = format!(
        "<script>window.__DUPLEX_CONFIG__={{jsLogs:{}}};</script>",
        if state.cfg.js_logs { "true" } else { "false" }
    );
    match html.find("<script") {
        Some(idx) => {
            let mut out = String::with_capacity(html.len() + cfg.len() + 8);
            out.push_str(&html[..idx]);
            out.push_str(&cfg);
            out.push_str(&html[idx..]);
            out
        }
        // No script tag found — append before </body> as a fallback, or just
        // return unchanged if even that's missing.
        None => match html.rfind("</body>") {
            Some(idx) => format!("{}{}{}", &html[..idx], cfg, &html[idx..]),
            None => html.to_string(),
        },
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
