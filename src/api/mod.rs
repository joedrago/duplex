use std::sync::Arc;

use axum::http::{HeaderName, HeaderValue};
use axum::Router;
use tower_http::cors::CorsLayer;
use tower_http::set_header::SetResponseHeaderLayer;
use tower_http::trace::TraceLayer;

use crate::config::Cli;
use crate::library::Library;

pub mod browse;
pub mod debug;
pub mod flatten;
pub mod houseparty;
pub mod manifest;
pub mod next;
pub mod poster;
pub mod raw;
pub mod recent;
pub mod search;
pub mod sidecar;
pub mod vpath;
pub mod web;

/// Shared, cheap-to-clone state injected into every handler.
#[derive(Clone)]
pub struct AppState {
    pub library: Library,
    pub cfg: Arc<Cli>,
    /// Shared "House Party" fake-player state — see `houseparty`.
    pub houseparty: houseparty::HouseParty,
}

pub fn router(state: AppState) -> Router {
    let cors = if state.cfg.dev_cors {
        CorsLayer::very_permissive()
    } else {
        CorsLayer::new()
    };

    // Cross-origin isolation: COOP+COEP make the page `crossOriginIsolated`,
    // unlocking `SharedArrayBuffer` and threaded WebAssembly for the client-
    // side player. CORP same-origin tags every response so it can be loaded
    // under COEP `require-corp` from our own document. Duplex is a single-
    // origin LAN server, so locking everything to same-origin is the safe
    // default.
    Router::new()
        .merge(browse::routes())
        .merge(manifest::routes())
        .merge(raw::routes())
        .merge(poster::routes())
        .merge(sidecar::routes())
        .merge(recent::routes())
        .merge(next::routes())
        .merge(flatten::routes())
        .merge(search::routes())
        .merge(houseparty::routes())
        .merge(debug::routes())
        .merge(web::routes())
        .with_state(state)
        .layer(cors)
        .layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("cross-origin-opener-policy"),
            HeaderValue::from_static("same-origin"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("cross-origin-embedder-policy"),
            HeaderValue::from_static("require-corp"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("cross-origin-resource-policy"),
            HeaderValue::from_static("same-origin"),
        ))
        .layer(TraceLayer::new_for_http())
}
