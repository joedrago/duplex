use std::sync::Arc;

use anyhow::Result;
use clap::Parser;
use tokio::net::TcpListener;
use tokio::signal;

mod api;
mod config;
mod library;

use crate::api::AppState;
use crate::config::Cli;
use crate::library::Library;

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

    let state = AppState {
        library,
        cfg: Arc::new(cli.clone()),
        houseparty: api::houseparty::new(),
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
