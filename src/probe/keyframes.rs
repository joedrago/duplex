//! Extract keyframe presentation timestamps for HLS segmentation.
//!
//! We read them from the container's own index (Matroska Cues for now) so
//! the operation is cheap enough that no on-disk cache is needed. If the
//! container won't give us an index quickly we return an error and the
//! file simply won't play — by design we never fall back to walking
//! every packet in the stream.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use anyhow::{anyhow, bail, Result};
use tokio::sync::Mutex;

use crate::probe::{matroska, Key};

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
    inner: Mutex<HashMap<Key, Arc<Keyframes>>>,
}

impl KeyframeCache {
    pub fn new() -> Self {
        Self {
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
        let kf = extract(path, duration_hint).await?;
        let arc = Arc::new(kf);
        let mut guard = self.inner.lock().await;
        guard.entry(key).or_insert_with(|| arc.clone());
        Ok(arc)
    }
}

impl Default for KeyframeCache {
    fn default() -> Self {
        Self::new()
    }
}

async fn extract(file: &Path, duration: f64) -> Result<Keyframes> {
    let ext = file
        .extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_ascii_lowercase());
    let is_matroska = matches!(
        ext.as_deref(),
        Some("mkv") | Some("webm") | Some("mka") | Some("mk3d")
    );
    if !is_matroska {
        bail!(
            "no fast keyframe path for {} (extension {:?})",
            file.display(),
            ext.as_deref().unwrap_or("")
        );
    }

    let p = file.to_path_buf();
    let t0 = std::time::Instant::now();
    let mut times = tokio::task::spawn_blocking(move || matroska::read_keyframe_times(&p))
        .await
        .map_err(|e| anyhow!("matroska parser panicked: {e}"))??;
    let parse_ms = t0.elapsed().as_millis();
    let raw_count = times.len();
    if times.first().map(|&t| t > 0.001).unwrap_or(true) {
        times.insert(0, 0.0);
    }
    tracing::debug!(
        file = %file.display(),
        parse_ms,
        raw_count,
        final_count = times.len(),
        first = times.first().copied().unwrap_or(0.0),
        last = times.last().copied().unwrap_or(0.0),
        duration_hint = duration,
        "matroska cues parsed",
    );
    Ok(Keyframes {
        times,
        duration: duration.max(0.0),
    })
}
