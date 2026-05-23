use std::sync::Arc;

use axum::Router;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use crate::config::Cli;
use crate::library::Library;
use crate::probe::keyframes::KeyframeCache;
use crate::probe::ProbeCache;
use crate::stream::StreamCache;

pub mod browse;
pub mod file;
pub mod hls;
pub mod raw;
pub mod subs;
pub mod vpath;
pub mod web;

/// Shared, cheap-to-clone state injected into every handler.
#[derive(Clone)]
pub struct AppState {
    pub library: Library,
    pub probe: Arc<ProbeCache>,
    pub keyframes: Arc<KeyframeCache>,
    pub streams: Arc<StreamCache>,
    pub cfg: Arc<Cli>,
}

pub fn router(state: AppState) -> Router {
    let cors = if state.cfg.dev_cors {
        CorsLayer::very_permissive()
    } else {
        CorsLayer::new()
    };

    Router::new()
        .merge(browse::routes())
        .merge(file::routes())
        .merge(raw::routes())
        .merge(hls::routes())
        .merge(subs::routes())
        .merge(web::routes())
        .with_state(state)
        .layer(cors)
        .layer(TraceLayer::new_for_http())
}
