//! Debug-only endpoints, gated by `--js-logs`.
//!
//! `POST /_debug/log` accepts a batch of client log entries and re-emits them
//! through the server's `tracing` subscriber so server and client logs
//! interleave in the same stdout. When the flag is off the handler returns
//! 404 so the route is effectively invisible.

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use serde::Deserialize;

use crate::api::AppState;

pub fn routes() -> Router<AppState> {
    Router::new().route("/_debug/log", post(log))
}

#[derive(Debug, Deserialize)]
struct ClientLog {
    /// "log" | "info" | "warn" | "error" — anything else is treated as info.
    level: String,
    /// Client `Date.now()` in milliseconds. Carried for ordering even if we
    /// don't print it; the server's own timestamp is what shows in stdout.
    #[serde(default)]
    #[allow(dead_code)]
    ts: f64,
    msg: String,
    #[serde(default)]
    stack: Option<String>,
}

async fn log(State(state): State<AppState>, Json(batch): Json<Vec<ClientLog>>) -> StatusCode {
    if !state.cfg.js_logs {
        return StatusCode::NOT_FOUND;
    }
    for e in batch {
        let body = match e.stack.as_deref() {
            Some(s) if !s.is_empty() => format!("[client] {}\n{}", e.msg, s),
            _ => format!("[client] {}", e.msg),
        };
        match e.level.as_str() {
            "error" => tracing::error!("{body}"),
            "warn" => tracing::warn!("{body}"),
            _ => tracing::info!("{body}"),
        }
    }
    StatusCode::NO_CONTENT
}
