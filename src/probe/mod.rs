//! ffprobe wrapper: lazy, memoised per (path, mtime, size).
//!
//! Probe results are JSON-serialisable so we can expose the full thing via
//! `/api/file` for debugging.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::SystemTime;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tokio::sync::Mutex;

pub mod keyframes;

#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub struct Key {
    pub path: PathBuf,
    pub mtime_nanos: u128,
    pub size: u64,
}

impl Key {
    pub fn new(path: &Path, mtime: SystemTime, size: u64) -> Self {
        let nanos = mtime
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        Self {
            path: path.to_path_buf(),
            mtime_nanos: nanos,
            size,
        }
    }
}

/// Top-level probe payload. We store the raw streams as deserialised structs
/// but also keep the original JSON so we can surface anything we missed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Probe {
    pub format: FormatInfo,
    pub streams: Vec<Stream>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FormatInfo {
    #[serde(default)]
    pub format_name: String,
    #[serde(default)]
    pub duration: Option<String>,
    #[serde(default)]
    pub bit_rate: Option<String>,
    #[serde(default)]
    pub size: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Stream {
    pub index: u32,
    pub codec_type: String,
    #[serde(default)]
    pub codec_name: Option<String>,
    #[serde(default)]
    pub profile: Option<String>,
    #[serde(default)]
    pub level: Option<i32>,
    #[serde(default)]
    pub width: Option<u32>,
    #[serde(default)]
    pub height: Option<u32>,
    #[serde(default)]
    pub pix_fmt: Option<String>,
    #[serde(default)]
    pub channels: Option<u32>,
    #[serde(default)]
    pub channel_layout: Option<String>,
    #[serde(default)]
    pub sample_rate: Option<String>,
    #[serde(default)]
    pub tags: Option<HashMap<String, String>>,
    #[serde(default)]
    pub disposition: Option<HashMap<String, i32>>,
}

impl Probe {
    pub fn duration_secs(&self) -> Option<f64> {
        self.format.duration.as_deref().and_then(|s| s.parse().ok())
    }

    pub fn video_stream(&self) -> Option<&Stream> {
        self.streams.iter().find(|s| s.codec_type == "video")
    }

    pub fn video_codec(&self) -> Option<&str> {
        self.video_stream().and_then(|s| s.codec_name.as_deref())
    }

    pub fn audio_streams(&self) -> impl Iterator<Item = &Stream> {
        self.streams.iter().filter(|s| s.codec_type == "audio")
    }

    pub fn subtitle_streams(&self) -> impl Iterator<Item = &Stream> {
        self.streams.iter().filter(|s| s.codec_type == "subtitle")
    }
}

/// Lazy, async-locked probe cache. Probes are run at most once per Key.
pub struct ProbeCache {
    ffprobe: PathBuf,
    inner: Mutex<HashMap<Key, Arc<Probe>>>,
}

impl ProbeCache {
    pub fn new(ffprobe: PathBuf) -> Self {
        Self {
            ffprobe,
            inner: Mutex::new(HashMap::new()),
        }
    }

    /// Synchronous, non-blocking lookup — returns None if not yet probed.
    /// Useful for browse responses that shouldn't trigger probes.
    pub fn cached(&self, path: &Path, size: u64, mtime: SystemTime) -> Option<Arc<Probe>> {
        let key = Key::new(path, mtime, size);
        self.inner.try_lock().ok()?.get(&key).cloned()
    }

    /// Probe (or return cached). May spawn ffprobe.
    pub async fn get_or_probe(
        &self,
        path: &Path,
        size: u64,
        mtime: SystemTime,
    ) -> Result<Arc<Probe>> {
        let key = Key::new(path, mtime, size);
        {
            let guard = self.inner.lock().await;
            if let Some(p) = guard.get(&key) {
                return Ok(p.clone());
            }
        }
        let probe = run_ffprobe(&self.ffprobe, path).await?;
        let arc = Arc::new(probe);
        let mut guard = self.inner.lock().await;
        guard.entry(key).or_insert_with(|| arc.clone());
        Ok(arc)
    }

}

async fn run_ffprobe(ffprobe: &Path, file: &Path) -> Result<Probe> {
    let output = Command::new(ffprobe)
        .args([
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
        ])
        .arg(file)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .with_context(|| format!("spawn ffprobe for {}", file.display()))?;
    if !output.status.success() {
        return Err(anyhow!(
            "ffprobe failed for {}: {}",
            file.display(),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let probe: Probe = serde_json::from_slice(&output.stdout)
        .with_context(|| format!("parse ffprobe json for {}", file.display()))?;
    Ok(probe)
}
