use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;

/// Duplex — a small, opinionated, read-only media server.
///
/// Everything is configured via flags. No config file. No on-disk state.
#[derive(Debug, Parser, Clone)]
#[command(name = "duplex", version, about)]
pub struct Cli {
    /// A library root to serve. Repeat for multiple roots; each appears as a
    /// top-level virtual directory named by its basename.
    /// Example: `--library /mnt/nas/Movies --library /mnt/nas/TV`
    #[arg(long = "library", value_name = "PATH", required = true, num_args = 1)]
    pub libraries: Vec<PathBuf>,

    /// A *hidden* library root. Mounted, watched, and playable exactly like
    /// `--library`, but withheld from every listing — it never shows up in the
    /// root browse, "recently added", search, or folder-flatten. The only way
    /// it surfaces is by typing its exact, case-sensitive basename into search,
    /// which returns it as a single browseable directory; from there it behaves
    /// like any other library. Repeat for multiple hidden roots. A hidden root
    /// may not share a basename with any other root, hidden or visible.
    /// Example: `--hidden /mnt/nas/ABC123`
    #[arg(long = "hidden", value_name = "PATH", num_args = 1)]
    pub hidden: Vec<PathBuf>,

    /// A public Letterboxd account (username) to overlay onto the library.
    /// Repeat for several family members. On startup — and again whenever a
    /// client hits Refresh — the server harvests each account's *public* watched
    /// films, ratings, hearts, and watchlist from letterboxd.com and correlates
    /// them, by title+year, to matching movies on disk. This is read-only and
    /// never persisted: the overlay lives only in memory and is re-fetched from
    /// scratch on boot. There is deliberately no polling timer — a harvest runs
    /// only at startup and on manual Refresh — to stay a polite visitor. Empty
    /// disables the feature entirely.
    /// Example: `--letterboxd joedrago --letterboxd janedoe`
    #[arg(long = "letterboxd", value_name = "ACCOUNT", num_args = 1)]
    pub letterboxd: Vec<String>,

    /// Address to bind the HTTP server.
    #[arg(
        long,
        value_name = "ADDR",
        default_value = "127.0.0.1:2345",
        env = "DUPLEX_BIND"
    )]
    pub bind: SocketAddr,

    /// Log level (trace/debug/info/warn/error) or any RUST_LOG-style filter.
    #[arg(long, value_name = "LEVEL", default_value = "info", env = "DUPLEX_LOG")]
    pub log: String,

    /// Filesystem-watcher debounce window, in milliseconds.
    #[arg(long, value_name = "MS", default_value_t = 300)]
    pub watch_debounce_ms: u64,

    /// Interval, in seconds, between full background re-scans of every library
    /// root. The event watcher is blind to network filesystems — CIFS/SMB
    /// mounts never deliver inotify/FSEvents notifications — so a periodic
    /// re-scan is the only way new files there are ever noticed. 0 disables it,
    /// leaving just the startup scan and the event watcher.
    #[arg(long, value_name = "SECS", default_value_t = 60)]
    pub rescan_secs: u64,

    /// Allow any origin (CORS). Off by default; turn on if serving the dev
    /// web client from a different port.
    #[arg(long, default_value_t = false)]
    pub dev_cors: bool,

    /// Mirror browser JS console output (console.log/warn/error, uncaught
    /// errors, unhandled promise rejections) into this process's stdout via
    /// the tracing facility, for unified server+client debugging. Adds
    /// `POST /_debug/log` and inlines `window.__DUPLEX_CONFIG__` into the
    /// served HTML so the client knows to install the shim.
    #[arg(long, default_value_t = false)]
    pub js_logs: bool,
}
