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

    /// Address to bind the HTTP server.
    #[arg(long, value_name = "ADDR", default_value = "127.0.0.1:2345", env = "DUPLEX_BIND")]
    pub bind: SocketAddr,

    /// Log level (trace/debug/info/warn/error) or any RUST_LOG-style filter.
    #[arg(long, value_name = "LEVEL", default_value = "info", env = "DUPLEX_LOG")]
    pub log: String,

    /// Path to the ffmpeg binary.
    #[arg(long, value_name = "PATH", default_value = "ffmpeg", env = "DUPLEX_FFMPEG")]
    pub ffmpeg: PathBuf,

    /// Path to the ffprobe binary.
    #[arg(long, value_name = "PATH", default_value = "ffprobe", env = "DUPLEX_FFPROBE")]
    pub ffprobe: PathBuf,

    /// Filesystem-watcher debounce window, in milliseconds.
    #[arg(long, value_name = "MS", default_value_t = 300)]
    pub watch_debounce_ms: u64,

    /// Allow any origin (CORS). Off by default; turn on if serving the dev
    /// web client from a different port.
    #[arg(long, default_value_t = false)]
    pub dev_cors: bool,
}
