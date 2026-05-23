//! Per-file HLS stream sessions, backed by in-process libav* via rsmpeg.
//!
//! For each `(file, audio_idx, transcode)` tuple we own one pump thread
//! that demuxes the source, optionally decodes/filters/re-encodes audio,
//! and muxes a fragmented MP4 directly into an in-memory segment buffer
//! via a custom AVIOContext. HTTP handlers `await` segments off that
//! buffer. The pump applies backpressure: it stops pulling packets when
//! the buffer is more than `LOOKAHEAD_SEGMENTS` ahead of the most-
//! recently-requested segment, and resumes when the consumer catches
//! up. Sliding-window eviction keeps total resident memory bounded.
//!
//! Forward scrubs past the buffered range tear the pump down and re-
//! init it at the new cluster start via `av_seek_frame`. Backward
//! scrubs into already-buffered territory are served from RAM.
//! Entries age out after an idle TTL.

mod pump;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex as StdMutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use bytes::Bytes;
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;

use crate::probe::keyframes::Keyframes;
use crate::probe::Key;

const LOOKAHEAD_SEGMENTS: usize = 12;
const SEGMENT_WAIT_TIMEOUT: Duration = Duration::from_secs(30);
const IDLE_TTL: Duration = Duration::from_secs(5 * 60);
const SWEEP_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Clone, Eq, PartialEq, Hash)]
pub struct StreamKey {
    pub file: Key,
    pub audio_idx: u32,
    pub transcode: bool,
}

pub struct StreamCache {
    inner: Mutex<HashMap<StreamKey, Arc<Stream>>>,
}

impl StreamCache {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    pub async fn get_or_create(
        &self,
        file: PathBuf,
        key: Key,
        keyframes: Arc<Keyframes>,
        audio_idx: u32,
        transcode: bool,
    ) -> Arc<Stream> {
        let sk = StreamKey {
            file: key,
            audio_idx,
            transcode,
        };
        let mut guard = self.inner.lock().await;
        if let Some(s) = guard.get(&sk) {
            s.touch();
            return s.clone();
        }
        let stream = Arc::new(Stream::new(file, keyframes, audio_idx, transcode));
        guard.insert(sk, stream.clone());
        stream
    }

    pub fn spawn_sweeper(self: Arc<Self>) -> JoinHandle<()> {
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(SWEEP_INTERVAL);
            loop {
                ticker.tick().await;
                let now = Instant::now();
                let mut guard = self.inner.lock().await;
                let before = guard.len();
                guard.retain(|_, s| {
                    let last = *s.last_touched.lock().unwrap();
                    now.duration_since(last) < IDLE_TTL
                });
                let after = guard.len();
                if before != after {
                    tracing::info!(
                        evicted = before - after,
                        remaining = after,
                        "stream cache sweep",
                    );
                }
            }
        })
    }
}

pub struct Stream {
    file: PathBuf,
    keyframes: Arc<Keyframes>,
    audio_idx: u32,
    transcode: bool,
    last_touched: StdMutex<Instant>,

    shared: Arc<Shared>,

    pump_handle: StdMutex<Option<std::thread::JoinHandle<()>>>,
}

/// State shared between the async serving side and the blocking pump.
pub(crate) struct Shared {
    pub(crate) state: StdMutex<State>,
    /// Async signal: pump → consumer when a new segment is appended,
    /// the init segment lands, or the pump errors out.
    pub(crate) new_data: Notify,
    /// Sync signal: consumer → pump when `last_requested_seg` advances
    /// or `should_stop` is set; pump waits on this when the buffer is
    /// full.
    pub(crate) drain: Condvar,
}

pub(crate) struct State {
    pub(crate) init_segment: Option<Bytes>,
    pub(crate) segments: HashMap<usize, Bytes>,
    pub(crate) leading_edge: Option<usize>,
    pub(crate) pump_start_seg: usize,
    pub(crate) last_requested_seg: usize,
    pub(crate) error: Option<String>,
    pub(crate) should_stop: bool,
}

impl Stream {
    fn new(file: PathBuf, keyframes: Arc<Keyframes>, audio_idx: u32, transcode: bool) -> Self {
        let shared = Arc::new(Shared {
            state: StdMutex::new(State {
                init_segment: None,
                segments: HashMap::new(),
                leading_edge: None,
                pump_start_seg: 0,
                last_requested_seg: 0,
                error: None,
                should_stop: false,
            }),
            new_data: Notify::new(),
            drain: Condvar::new(),
        });
        Self {
            file,
            keyframes,
            audio_idx,
            transcode,
            last_touched: StdMutex::new(Instant::now()),
            shared,
            pump_handle: StdMutex::new(None),
        }
    }

    pub fn touch(&self) {
        *self.last_touched.lock().unwrap() = Instant::now();
    }

    pub async fn init_segment(self: &Arc<Self>) -> Result<Bytes> {
        self.touch();
        self.ensure_pump(0);
        let deadline = Instant::now() + SEGMENT_WAIT_TIMEOUT;
        loop {
            {
                let s = self.shared.state.lock().unwrap();
                if let Some(b) = s.init_segment.clone() {
                    return Ok(b);
                }
                if let Some(e) = s.error.as_ref() {
                    bail!("pump error: {e}");
                }
            }
            self.wait_for_change(deadline).await?;
        }
    }

    pub async fn segment(self: &Arc<Self>, n: usize) -> Result<Bytes> {
        self.touch();
        {
            let mut s = self.shared.state.lock().unwrap();
            if n > s.last_requested_seg {
                s.last_requested_seg = n;
                self.shared.drain.notify_all();
            }
            if let Some(b) = s.segments.get(&n) {
                return Ok(b.clone());
            }
            if let Some(e) = s.error.as_ref() {
                bail!("pump error: {e}");
            }
        }
        if self.should_restart(n) {
            self.restart_at(n);
        }
        self.ensure_pump(n);
        let deadline = Instant::now() + SEGMENT_WAIT_TIMEOUT;
        loop {
            {
                let s = self.shared.state.lock().unwrap();
                if let Some(b) = s.segments.get(&n) {
                    return Ok(b.clone());
                }
                if let Some(e) = s.error.as_ref() {
                    bail!("pump error: {e}");
                }
            }
            self.wait_for_change(deadline).await?;
        }
    }

    fn should_restart(&self, n: usize) -> bool {
        if self.pump_handle.lock().unwrap().is_none() {
            return true;
        }
        let s = self.shared.state.lock().unwrap();
        if n < s.pump_start_seg {
            return true;
        }
        if let Some(edge) = s.leading_edge {
            if n > edge + LOOKAHEAD_SEGMENTS * 2 {
                return true;
            }
        }
        false
    }

    fn restart_at(self: &Arc<Self>, n: usize) {
        {
            let mut s = self.shared.state.lock().unwrap();
            s.should_stop = true;
        }
        self.shared.drain.notify_all();
        if let Some(handle) = self.pump_handle.lock().unwrap().take() {
            let shared = self.shared.clone();
            std::thread::spawn(move || {
                let _ = handle.join();
                let mut s = shared.state.lock().unwrap();
                s.should_stop = false;
                s.error = None;
                s.init_segment = None;
                s.leading_edge = None;
                s.pump_start_seg = n;
            });
        }
        // Caller will call ensure_pump(n) next, which (re)spawns at n.
    }

    fn ensure_pump(self: &Arc<Self>, start_seg: usize) {
        let mut handle_slot = self.pump_handle.lock().unwrap();
        if handle_slot.is_some() {
            return;
        }
        let segs = self.keyframes.segments();
        let start_time = segs.get(start_seg).map(|(s, _)| *s).unwrap_or(0.0);
        {
            let mut s = self.shared.state.lock().unwrap();
            s.pump_start_seg = start_seg;
            s.last_requested_seg = s.last_requested_seg.max(start_seg);
            s.error = None;
            s.should_stop = false;
        }
        let cfg = pump::Config {
            file: self.file.clone(),
            audio_idx: self.audio_idx,
            transcode: self.transcode,
            start_time,
            start_seg,
        };
        let shared = self.shared.clone();
        let handle = std::thread::Builder::new()
            .name(format!(
                "duplex-pump:{}:{}",
                self.file
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("?"),
                self.audio_idx,
            ))
            .spawn(move || pump::run(cfg, shared))
            .expect("spawn pump thread");
        *handle_slot = Some(handle);
    }

    async fn wait_for_change(&self, deadline: Instant) -> Result<()> {
        let now = Instant::now();
        if now >= deadline {
            bail!("timed out waiting for stream progress");
        }
        let remaining = deadline - now;
        tokio::time::timeout(remaining, self.shared.new_data.notified())
            .await
            .map_err(|_| anyhow!("timed out waiting for stream progress"))?;
        Ok(())
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        {
            let mut s = self.shared.state.lock().unwrap();
            s.should_stop = true;
        }
        self.shared.drain.notify_all();
        if let Some(handle) = self.pump_handle.lock().unwrap().take() {
            let _ = handle.join();
        }
    }
}
