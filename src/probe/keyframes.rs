//! Extract keyframe presentation timestamps from the video stream.
//!
//! Cached per-file in memory. Used to compute HLS segment boundaries that
//! coincide with keyframes (so we can `-c:v copy`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::SystemTime;

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use tokio::process::Command;
use tokio::sync::Mutex;

use crate::probe::Key;

#[derive(Debug, Clone, Default)]
pub struct Keyframes {
    /// PTS times in seconds, sorted ascending. Always starts with 0.0.
    pub times: Vec<f64>,
    /// Total stream duration in seconds.
    pub duration: f64,
}

impl Keyframes {
    /// Build (start, duration) pairs for each segment.
    pub fn segments(&self) -> Vec<(f64, f64)> {
        let mut out = Vec::with_capacity(self.times.len());
        for (i, t) in self.times.iter().enumerate() {
            let end = if i + 1 < self.times.len() {
                self.times[i + 1]
            } else {
                self.duration
            };
            let dur = (end - t).max(0.0);
            if dur > 0.001 {
                out.push((*t, dur));
            }
        }
        out
    }

    pub fn target_duration(&self) -> u32 {
        self.segments()
            .iter()
            .map(|(_, d)| d.ceil() as u32)
            .max()
            .unwrap_or(10)
            .max(1)
    }
}

pub struct KeyframeCache {
    ffprobe: PathBuf,
    inner: Mutex<HashMap<Key, Arc<Keyframes>>>,
}

impl KeyframeCache {
    pub fn new(ffprobe: PathBuf) -> Self {
        Self {
            ffprobe,
            inner: Mutex::new(HashMap::new()),
        }
    }

    pub async fn get_or_extract(
        &self,
        path: &Path,
        size: u64,
        mtime: SystemTime,
        duration_hint: f64,
    ) -> Result<Arc<Keyframes>> {
        let key = Key::new(path, mtime, size);
        {
            let guard = self.inner.lock().await;
            if let Some(k) = guard.get(&key) {
                return Ok(k.clone());
            }
        }
        let kf = extract(&self.ffprobe, path, duration_hint).await?;
        let arc = Arc::new(kf);
        let mut guard = self.inner.lock().await;
        guard.entry(key).or_insert_with(|| arc.clone());
        Ok(arc)
    }

}

#[derive(Debug, Deserialize)]
struct Packet {
    pts_time: Option<String>,
    /// e.g. "K_" for a keyframe (discardable), "K__" with various trailing flags.
    flags: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Wrap {
    #[serde(default)]
    packets: Vec<Packet>,
}

async fn extract(ffprobe: &Path, file: &Path, duration: f64) -> Result<Keyframes> {
    let output = Command::new(ffprobe)
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_packets",
            "-show_entries",
            "packet=pts_time,flags",
            "-print_format",
            "json",
        ])
        .arg(file)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .with_context(|| format!("spawn ffprobe keyframes for {}", file.display()))?;
    if !output.status.success() {
        return Err(anyhow!(
            "ffprobe keyframes failed for {}: {}",
            file.display(),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let wrap: Wrap = serde_json::from_slice(&output.stdout)
        .with_context(|| format!("parse keyframe json for {}", file.display()))?;
    let mut times: Vec<f64> = wrap
        .packets
        .into_iter()
        .filter(|p| p.flags.as_deref().map(|f| f.contains('K')).unwrap_or(false))
        .filter_map(|p| p.pts_time.and_then(|s| s.parse::<f64>().ok()))
        .collect();
    times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    if times.first().map(|&t| t > 0.001).unwrap_or(true) {
        times.insert(0, 0.0);
    }
    Ok(Keyframes {
        times,
        duration: duration.max(0.0),
    })
}
