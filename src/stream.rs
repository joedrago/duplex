//! Per-file HLS stream sessions.
//!
//! For each `(file, audio_idx, transcode)` tuple we keep at most one long-
//! lived ffmpeg subprocess producing a fragmented MP4 to stdout. A reader
//! task carves that byte stream at moof boundaries and stuffs each
//! `moof+mdat` fragment into an in-memory segment buffer. HTTP handlers
//! `await` on a Notify until the segment they want shows up.
//!
//! Forward scrubs past the buffered range trigger an ffmpeg restart at the
//! cluster start of the requested segment. Backward scrubs into already-
//! buffered territory are served from RAM. Entries age out after an idle
//! TTL so unused streams release their ffmpeg + memory.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::{Child, ChildStderr, ChildStdout, Command};
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;

use crate::probe::keyframes::Keyframes;
use crate::probe::Key;

const LOOKAHEAD_SEGMENTS: usize = 30;
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
    ffmpeg_path: PathBuf,
}

impl StreamCache {
    pub fn new(ffmpeg_path: PathBuf) -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            ffmpeg_path,
        }
    }

    /// Look up or create a stream session. Always touches `last_touched`.
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
        let stream = Arc::new(Stream::new(
            file,
            keyframes,
            audio_idx,
            transcode,
            self.ffmpeg_path.clone(),
        ));
        guard.insert(sk, stream.clone());
        stream
    }

    /// Periodically drop entries that haven't been touched within IDLE_TTL.
    /// Killing the Stream's `Arc` drops the FfmpegHandle which kills ffmpeg.
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
    ffmpeg_path: PathBuf,

    last_touched: std::sync::Mutex<Instant>,
    inner: Mutex<StreamInner>,
    notify: Notify,
}

struct StreamInner {
    init_segment: Option<Bytes>,
    segments: HashMap<usize, Bytes>,
    ffmpeg: Option<FfmpegHandle>,

    // Current ffmpeg's lowest emitted segment index and the highest one
    // we've stored for it. None until ffmpeg starts producing.
    ffmpeg_start_seg: usize,
    leading_edge: Option<usize>,
}

struct FfmpegHandle {
    child: Child,
    reader: JoinHandle<()>,
}

impl Drop for FfmpegHandle {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
        self.reader.abort();
    }
}

impl Stream {
    fn new(
        file: PathBuf,
        keyframes: Arc<Keyframes>,
        audio_idx: u32,
        transcode: bool,
        ffmpeg_path: PathBuf,
    ) -> Self {
        Self {
            file,
            keyframes,
            audio_idx,
            transcode,
            ffmpeg_path,
            last_touched: std::sync::Mutex::new(Instant::now()),
            inner: Mutex::new(StreamInner {
                init_segment: None,
                segments: HashMap::new(),
                ffmpeg: None,
                ffmpeg_start_seg: 0,
                leading_edge: None,
            }),
            notify: Notify::new(),
        }
    }

    pub fn touch(&self) {
        *self.last_touched.lock().unwrap() = Instant::now();
    }

    pub async fn init_segment(self: &Arc<Self>) -> Result<Bytes> {
        self.touch();
        let deadline = Instant::now() + SEGMENT_WAIT_TIMEOUT;
        loop {
            let mut inner = self.inner.lock().await;
            if let Some(b) = inner.init_segment.clone() {
                return Ok(b);
            }
            if inner.ffmpeg.is_none() {
                self.spawn_ffmpeg(&mut inner, 0).await?;
            }
            drop(inner);
            self.wait_for_change(deadline).await?;
        }
    }

    pub async fn segment(self: &Arc<Self>, n: usize) -> Result<Bytes> {
        self.touch();
        let deadline = Instant::now() + SEGMENT_WAIT_TIMEOUT;
        loop {
            let mut inner = self.inner.lock().await;
            if let Some(b) = inner.segments.get(&n) {
                return Ok(b.clone());
            }
            if self.should_restart(&inner, n) {
                self.spawn_ffmpeg(&mut inner, n).await?;
            }
            drop(inner);
            self.wait_for_change(deadline).await?;
        }
    }

    fn should_restart(&self, inner: &StreamInner, n: usize) -> bool {
        if inner.ffmpeg.is_none() {
            return true;
        }
        if n < inner.ffmpeg_start_seg {
            return true;
        }
        match inner.leading_edge {
            Some(edge) if n > edge + LOOKAHEAD_SEGMENTS => true,
            None if n > inner.ffmpeg_start_seg + LOOKAHEAD_SEGMENTS => true,
            _ => false,
        }
    }

    async fn wait_for_change(&self, deadline: Instant) -> Result<()> {
        let now = Instant::now();
        if now >= deadline {
            bail!("timed out waiting for stream progress");
        }
        let remaining = deadline - now;
        tokio::time::timeout(remaining, self.notify.notified())
            .await
            .map_err(|_| anyhow!("timed out waiting for stream progress"))?;
        Ok(())
    }

    async fn spawn_ffmpeg(self: &Arc<Self>, inner: &mut StreamInner, start_seg: usize) -> Result<()> {
        let segs = self.keyframes.segments();
        let start_time = segs
            .get(start_seg)
            .map(|(s, _)| *s)
            .ok_or_else(|| anyhow!("segment {start_seg} out of range"))?;

        let mut cmd = Command::new(&self.ffmpeg_path);
        cmd.args(["-v", "warning"])
            .args(["-ss", &format!("{start_time:.6}")])
            .args(["-i"])
            .arg(&self.file)
            // -copyts: keep input PTS so moof tfdt matches the segment's
            // real global time (fixes hls.js oscillating between
            // adjacent segments on a scrub-target lookup).
            .args(["-copyts"])
            .args(["-map", "0:v:0"])
            .args(["-map", &format!("0:{}", self.audio_idx)])
            .args(["-c:v", "copy"]);
        if self.transcode {
            // Explicit 5.1→2.0 downmix in the filter graph (ITU-R BS.775
            // coefficients, side channels treated like back channels) so
            // the AAC encoder sees stereo input directly instead of doing
            // an implicit downmix. Without this, surround sources land
            // ~50-100ms ahead/behind video — likely the encoder's
            // internal channel-conversion buffer slipping in only on
            // the audio side. `aresample=async=1` after the downmix
            // keeps audio aligned with the video clock for any further
            // drift.
            cmd.args([
                "-c:a", "aac",
                "-b:a", "192k",
                "-ar", "48000",
                "-af",
                "pan=stereo|FL=1.0*FL+0.707*FC+0.707*SL+0.707*BL|FR=1.0*FR+0.707*FC+0.707*SR+0.707*BR,aresample=async=1",
            ]);
        } else {
            cmd.args(["-c:a", "copy"]);
        }
        cmd.args([
            "-f",
            "mp4",
            "-movflags",
            "+empty_moov+delay_moov+frag_keyframe+default_base_moof+omit_tfhd_offset",
            "pipe:1",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

        tracing::debug!(
            target: "ffmpeg",
            file = %self.file.display(),
            audio_idx = self.audio_idx,
            transcode = self.transcode,
            start_seg,
            start_time,
            "spawning streaming ffmpeg",
        );

        let mut child = cmd.spawn().context("spawn streaming ffmpeg")?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("ffmpeg stdout unavailable"))?;
        if let Some(stderr) = child.stderr.take() {
            let file = self.file.clone();
            tokio::spawn(stream_stderr(stderr, file));
        }

        // Replace any prior ffmpeg first: Drop kills the previous child + aborts its reader.
        inner.ffmpeg = None;
        inner.init_segment = None;
        inner.ffmpeg_start_seg = start_seg;
        inner.leading_edge = None;

        let weak = Arc::downgrade(self);
        let file_for_reader = self.file.clone();
        let reader = tokio::spawn(async move {
            if let Some(strong) = weak.upgrade() {
                match read_fragments(stdout, strong.clone(), start_seg).await {
                    Ok(()) => {
                        let count = strong.inner.lock().await.segments.len();
                        tracing::warn!(
                            target: "ffmpeg",
                            file = %file_for_reader.display(),
                            segments_buffered = count,
                            "fragment reader hit clean EOF (ffmpeg stdout closed)",
                        );
                    }
                    Err(e) => {
                        tracing::warn!(
                            target: "ffmpeg",
                            file = %file_for_reader.display(),
                            "fragment reader error: {e:#}",
                        );
                    }
                }
            }
        });

        inner.ffmpeg = Some(FfmpegHandle { child, reader });
        Ok(())
    }
}

/// Pump ffmpeg's stderr line-by-line into tracing so we see warnings and
/// errors as they happen, not at process EOF.
async fn stream_stderr(stderr: ChildStderr, file: std::path::PathBuf) {
    let mut lines = BufReader::new(stderr).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                if !line.trim().is_empty() {
                    tracing::debug!(target: "ffmpeg", file = %file.display(), "stderr: {}", line);
                }
            }
            Ok(None) => return,
            Err(_) => return,
        }
    }
}

/// Pump ffmpeg's stdout: read MP4 boxes, recognise ftyp/moov/moof/mdat,
/// emit the init segment (everything up to the first moof) and each
/// moof+mdat pair as the indexed media segment, starting from
/// `start_seg`.
async fn read_fragments(
    stdout: ChildStdout,
    stream: Arc<Stream>,
    start_seg: usize,
) -> Result<()> {
    let mut reader = BufReader::with_capacity(256 * 1024, stdout);
    let mut init_buf: Vec<u8> = Vec::with_capacity(64 * 1024);
    let mut next_seg = start_seg;
    let mut pending_moof: Option<Vec<u8>> = None;

    loop {
        let Some((kind, body)) = read_box(&mut reader).await? else {
            return Ok(());
        };

        match &kind {
            b"moof" => {
                pending_moof = Some(body);
            }
            b"mdat" => {
                if let Some(moof) = pending_moof.take() {
                    let mut combined = Vec::with_capacity(moof.len() + body.len());
                    combined.extend_from_slice(&moof);
                    combined.extend_from_slice(&body);
                    let mut inner = stream.inner.lock().await;
                    if inner.init_segment.is_none() && !init_buf.is_empty() {
                        inner.init_segment = Some(Bytes::from(std::mem::take(&mut init_buf)));
                    }
                    inner.segments.insert(next_seg, Bytes::from(combined));
                    inner.leading_edge = Some(next_seg);
                    next_seg += 1;
                    stream.notify.notify_waiters();
                }
            }
            _ => {
                if pending_moof.is_some() {
                    // Unexpected box between moof and mdat; discard pending.
                    pending_moof = None;
                }
                if stream.inner.lock().await.init_segment.is_none() {
                    init_buf.extend_from_slice(&body);
                }
            }
        }
    }
}

/// Read one top-level MP4 box from `reader`. Returns Ok(None) on clean EOF
/// before any header byte is read.
///
/// Handles three size encodings:
///   * 32-bit size (1..=8 invalid; >= 8 normal)
///   * size=1 → next 8 bytes hold the actual 64-bit size (header is 16 bytes)
///   * size=0 → box extends to EOF. We read everything that's left as the
///     body and signal EOF on the next call.
async fn read_box<R: AsyncReadExt + Unpin>(reader: &mut R) -> Result<Option<([u8; 4], Vec<u8>)>> {
    let mut header = [0u8; 8];
    let mut read_so_far = 0;
    while read_so_far < 8 {
        let n = reader.read(&mut header[read_so_far..]).await?;
        if n == 0 {
            if read_so_far == 0 {
                return Ok(None);
            }
            bail!("EOF mid-header");
        }
        read_so_far += n;
    }
    let size_field = u32::from_be_bytes(header[..4].try_into().unwrap()) as u64;
    let mut kind = [0u8; 4];
    kind.copy_from_slice(&header[4..8]);

    let mut full = Vec::with_capacity(8);
    full.extend_from_slice(&header);

    if size_field == 0 {
        reader.read_to_end(&mut full).await?;
        return Ok(Some((kind, full)));
    }

    let total = if size_field == 1 {
        let mut ext = [0u8; 8];
        reader.read_exact(&mut ext).await?;
        full.extend_from_slice(&ext);
        let ext_size = u64::from_be_bytes(ext);
        if ext_size < 16 {
            bail!("extended box size {ext_size} < 16");
        }
        ext_size
    } else if size_field < 8 {
        bail!("box size {size_field} < 8");
    } else {
        size_field
    };

    let body_len = (total as usize).saturating_sub(full.len());
    let mut body = vec![0u8; body_len];
    let mut read = 0;
    while read < body_len {
        let n = reader.read(&mut body[read..]).await?;
        if n == 0 {
            bail!("EOF mid-body");
        }
        read += n;
    }
    full.extend_from_slice(&body);
    Ok(Some((kind, full)))
}
