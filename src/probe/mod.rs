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
pub mod matroska;

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

    // PTS (seconds) of the *first packet* this stream emits, as observed by
    // a packet-level scan. Distinct from ffprobe's stream-level
    // `start_time`, which can claim 0.0 while the actual first packet is far
    // later (Matroska files where the audio track is mastered to start mid-
    // movie behave this way). Populated only for audio streams, since the
    // current capability decision is the only consumer.
    #[serde(default)]
    pub first_packet_pts: Option<f64>,
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
    let mut probe: Probe = serde_json::from_slice(&output.stdout)
        .with_context(|| format!("parse ffprobe json for {}", file.display()))?;
    annotate_first_audio_pts(ffprobe, file, &mut probe).await;
    Ok(probe)
}

// Second pass: find each audio stream's *first packet* PTS. Stream-level
// metadata can claim start_time=0 while real packets begin many seconds in
// (Matroska files mastered with a silent opening do this). The capability
// decision uses this to switch from passthrough-mux to transcode so the
// gap can be padded with silence — otherwise MSE stalls waiting for audio
// that doesn't exist in the source.
//
// We scan only the first 60s of stream content. Anything farther in counts
// as "definitely a gap" without needing a precise value.
async fn annotate_first_audio_pts(ffprobe: &Path, file: &Path, probe: &mut Probe) {
    let has_audio = probe.streams.iter().any(|s| s.codec_type == "audio");
    if !has_audio {
        return;
    }
    let output = Command::new(ffprobe)
        .args([
            "-v",
            "error",
            "-select_streams",
            "a",
            "-read_intervals",
            "%+60",
            "-show_entries",
            "packet=stream_index,pts_time",
            "-of",
            "csv=p=0",
        ])
        .arg(file)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await;
    let Ok(output) = output else { return };
    if !output.status.success() {
        return;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    // Track the minimum pts_time seen per stream index. Stream order in the
    // file isn't guaranteed strictly ascending in PTS (interleaving), so we
    // take the smallest, not just the first.
    let mut earliest: HashMap<u32, f64> = HashMap::new();
    for line in stdout.lines() {
        let mut parts = line.split(',');
        let Some(idx) = parts.next().and_then(|s| s.parse::<u32>().ok()) else {
            continue;
        };
        let Some(pts) = parts.next().and_then(|s| s.parse::<f64>().ok()) else {
            continue;
        };
        earliest
            .entry(idx)
            .and_modify(|cur| {
                if pts < *cur {
                    *cur = pts;
                }
            })
            .or_insert(pts);
    }
    for s in probe.streams.iter_mut() {
        if s.codec_type == "audio" {
            // If the stream isn't represented in the first 60s window at all,
            // treat that as a >60s gap so the decision engine forces transcode.
            s.first_packet_pts = Some(earliest.get(&s.index).copied().unwrap_or(60.0));
        }
    }
}
