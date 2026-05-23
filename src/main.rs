use std::sync::Arc;

use anyhow::Result;
use clap::Parser;
use tokio::net::TcpListener;
use tokio::signal;

mod api;
mod capability;
mod config;
mod ffmpeg;
mod library;
mod probe;
mod stream;

use crate::api::AppState;
use crate::config::Cli;
use crate::library::Library;
use crate::probe::keyframes::KeyframeCache;
use crate::probe::ProbeCache;
use crate::stream::StreamCache;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    init_tracing(&cli.log);

    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        roots = cli.libraries.len(),
        bind = %cli.bind,
        "starting duplex",
    );

    let library = Library::new(&cli.libraries)?;
    let tree = library::scan::scan(&library);
    library.replace(tree);
    tracing::info!(
        roots = library.roots.len(),
        top_level = library.snapshot().root_dir().children.len(),
        "initial scan complete"
    );

    library::watcher::spawn(library.clone(), cli.watch_debounce_ms)?;

    let probe = Arc::new(ProbeCache::new(cli.ffprobe.clone()));
    let keyframes = Arc::new(KeyframeCache::new());
    let streams = Arc::new(StreamCache::new());
    streams.clone().spawn_sweeper();

    let state = AppState {
        library,
        probe,
        keyframes,
        streams,
        cfg: Arc::new(cli.clone()),
    };
    let app = api::router(state);

    let listener = TcpListener::bind(cli.bind).await?;
    tracing::info!(addr = %cli.bind, "listening");

    // Race the server against the shutdown signal rather than using
    // `with_graceful_shutdown`, which waits for every in-flight connection
    // (browser keep-alives, pending segment fetches) to close before
    // returning. Dropping the serve future on Ctrl-C kills idle and
    // in-flight connections together so the process exits immediately.
    tokio::select! {
        res = axum::serve(listener, app) => res?,
        _ = shutdown_signal() => {}
    }
    Ok(())
}

fn init_tracing(filter: &str) {
    let env_filter = tracing_subscriber::EnvFilter::try_new(filter)
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_target(false)
        .with_writer(std::io::stderr)
        .init();
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c().await.expect("install Ctrl-C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => tracing::info!("received Ctrl-C, shutting down"),
        _ = terminate => tracing::info!("received SIGTERM, shutting down"),
    }
}
