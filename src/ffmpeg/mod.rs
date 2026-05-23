//! ffmpeg subprocess driver.
//!
//! Two shapes of ffmpeg invocation:
//!   * **init segment**: produces ftyp + moov (codec params); we slice off
//!     anything after the first 'moof' box.
//!   * **media segment**: produces ftyp + moov + moof + mdat for a single
//!     keyframe-aligned slice; we slice off everything *before* the first
//!     'moof' so the segment matches the EXT-X-MAP-defined init.
//!
//! Segments are buffered in memory (typically a few MB). The few-MB cost is a
//! reasonable trade for "ffmpeg writes a real moov, we strip and forward."
//!
//! ffmpeg flags worth knowing:
//!   * `+empty_moov`     — write a moov with no sample table up front
//!   * `+delay_moov`     — wait until the first packet is parsed before writing
//!     the moov, so codec params are known. Required for codecs like EAC-3
//!     and AC-3 in MP4.
//!   * `+frag_keyframe`  — start a new fragment at each keyframe.
//!   * `+default_base_moof` — required for MSE.
//!   * `+omit_tfhd_offset`  — avoid absolute byte references in tfhd.

use std::path::Path;
use std::process::Stdio;

use anyhow::{anyhow, Context, Result};
use bytes::Bytes;
use futures::stream::{Stream, StreamExt};
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio_util::io::ReaderStream;

const MOVFLAGS: &str =
    "+empty_moov+delay_moov+frag_keyframe+default_base_moof+omit_tfhd_offset";

pub async fn init_segment_video(ffmpeg: &Path, file: &Path) -> Result<Bytes> {
    init_segment_common(ffmpeg, file, MapSpec::Video).await
}

pub async fn init_segment_audio(
    ffmpeg: &Path,
    file: &Path,
    stream_index: u32,
    transcode: bool,
) -> Result<Bytes> {
    init_segment_common(
        ffmpeg,
        file,
        MapSpec::Audio {
            index: stream_index,
            transcode,
        },
    )
    .await
}

pub async fn segment_video(
    ffmpeg: &Path,
    file: &Path,
    start: f64,
    duration: f64,
) -> Result<Bytes> {
    let bytes = run_segment(ffmpeg, file, start, duration, MapSpec::Video).await?;
    let stripped = slice_from_first_moof(&bytes)
        .ok_or_else(|| anyhow!("video segment had no moof; ffmpeg output {} bytes", bytes.len()))?;
    Ok(Bytes::copy_from_slice(stripped))
}

pub async fn segment_audio(
    ffmpeg: &Path,
    file: &Path,
    stream_index: u32,
    start: f64,
    duration: f64,
    transcode: bool,
) -> Result<Bytes> {
    let bytes = run_segment(
        ffmpeg,
        file,
        start,
        duration,
        MapSpec::Audio {
            index: stream_index,
            transcode,
        },
    )
    .await?;
    let stripped = slice_from_first_moof(&bytes)
        .ok_or_else(|| anyhow!("audio segment had no moof; ffmpeg output {} bytes", bytes.len()))?;
    Ok(Bytes::copy_from_slice(stripped))
}

pub fn sidecar_to_vtt(
    ffmpeg: &Path,
    file: &Path,
    _format: &str,
) -> impl Stream<Item = Result<Bytes, std::io::Error>> {
    let ffmpeg = ffmpeg.to_path_buf();
    let file = file.to_path_buf();
    spawn_stream(move || {
        let mut cmd = Command::new(&ffmpeg);
        cmd.args(["-v", "error", "-i"])
            .arg(&file)
            .args(["-f", "webvtt", "pipe:1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        cmd
    })
}

pub fn embedded_sub_to_vtt(
    ffmpeg: &Path,
    file: &Path,
    stream_index: u32,
) -> impl Stream<Item = Result<Bytes, std::io::Error>> {
    let ffmpeg = ffmpeg.to_path_buf();
    let file = file.to_path_buf();
    spawn_stream(move || {
        let mut cmd = Command::new(&ffmpeg);
        cmd.args(["-v", "error", "-i"])
            .arg(&file)
            .args(["-map", &format!("0:{stream_index}")])
            .args(["-c:s", "webvtt", "-f", "webvtt", "pipe:1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        cmd
    })
}

#[derive(Clone, Copy)]
enum MapSpec {
    Video,
    Audio { index: u32, transcode: bool },
}

fn add_map_args(cmd: &mut Command, spec: MapSpec) {
    match spec {
        MapSpec::Video => {
            cmd.args(["-map", "0:v:0", "-c:v", "copy", "-an"]);
        }
        MapSpec::Audio { index, transcode } => {
            cmd.args(["-map", &format!("0:{index}"), "-vn"]);
            if transcode {
                cmd.args(["-c:a", "aac", "-ac", "2", "-b:a", "192k"]);
            } else {
                cmd.args(["-c:a", "copy"]);
            }
        }
    }
}

async fn init_segment_common(ffmpeg: &Path, file: &Path, spec: MapSpec) -> Result<Bytes> {
    let mut cmd = Command::new(ffmpeg);
    cmd.args(["-v", "error", "-i"]).arg(file).args(["-t", "0.5"]);
    add_map_args(&mut cmd, spec);
    cmd.args(["-f", "mp4", "-movflags", MOVFLAGS, "pipe:1"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let output = cmd.output().await.context("spawn ffmpeg (init)")?;
    if !output.status.success() {
        return Err(anyhow!(
            "ffmpeg init failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let init = match slice_up_to_first_moof(&output.stdout) {
        Some(s) => s,
        None => &output.stdout,
    };
    if init.is_empty() {
        return Err(anyhow!("ffmpeg produced empty init segment"));
    }
    Ok(Bytes::copy_from_slice(init))
}

async fn run_segment(
    ffmpeg: &Path,
    file: &Path,
    start: f64,
    duration: f64,
    spec: MapSpec,
) -> Result<Bytes> {
    let mut cmd = Command::new(ffmpeg);
    cmd.args(["-v", "error"])
        .args(["-ss", &format!("{start:.6}")])
        .args(["-i"])
        .arg(file)
        .args(["-t", &format!("{duration:.6}")]);
    add_map_args(&mut cmd, spec);
    cmd.args(["-f", "mp4", "-movflags", MOVFLAGS, "pipe:1"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let output = cmd.output().await.context("spawn ffmpeg (segment)")?;
    if !output.status.success() {
        return Err(anyhow!(
            "ffmpeg segment failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(Bytes::from(output.stdout))
}

/// Boxed streaming helper for VTT outputs. Spawns ffmpeg, streams stdout chunks.
fn spawn_stream<F>(build: F) -> impl Stream<Item = Result<Bytes, std::io::Error>>
where
    F: FnOnce() -> Command,
{
    async_stream::try_stream! {
        let mut cmd = build();
        cmd.kill_on_drop(true);
        let mut child = cmd.spawn().map_err(|e| std::io::Error::other(format!("ffmpeg spawn: {e}")))?;
        let stdout = child.stdout.take().ok_or_else(|| std::io::Error::other("no stdout"))?;
        let mut stderr = child.stderr.take();
        let mut reader = ReaderStream::new(stdout);
        while let Some(chunk) = reader.next().await {
            yield chunk?;
        }
        if let Some(mut e) = stderr.take() {
            let mut buf = String::new();
            let _ = e.read_to_string(&mut buf).await;
            if !buf.is_empty() {
                tracing::debug!(target: "ffmpeg", "stderr: {}", buf.trim());
            }
        }
        let _ = child.wait().await;
    }
}

/// Return the prefix of an ISO-BMFF byte stream up to (but not including) the
/// first 'moof' box. That prefix is a valid init segment (ftyp + moov).
fn slice_up_to_first_moof(buf: &[u8]) -> Option<&[u8]> {
    iter_boxes(buf).find_map(|(off, kind, _)| (kind == *b"moof").then_some(&buf[..off]))
}

/// Return the slice of an ISO-BMFF byte stream starting at the first 'moof' box.
/// That slice is a valid HLS-fMP4 media segment (moof + mdat...).
fn slice_from_first_moof(buf: &[u8]) -> Option<&[u8]> {
    iter_boxes(buf).find_map(|(off, kind, _)| (kind == *b"moof").then_some(&buf[off..]))
}

/// Iterate top-level boxes: (offset, four_cc, size).
fn iter_boxes(buf: &[u8]) -> impl Iterator<Item = (usize, [u8; 4], usize)> + '_ {
    let mut i = 0usize;
    std::iter::from_fn(move || {
        if i + 8 > buf.len() {
            return None;
        }
        let size_field = u32::from_be_bytes(buf[i..i + 4].try_into().ok()?) as usize;
        let mut kind = [0u8; 4];
        kind.copy_from_slice(&buf[i + 4..i + 8]);
        let box_size = match size_field {
            0 => buf.len() - i,
            1 => {
                if i + 16 > buf.len() {
                    return None;
                }
                u64::from_be_bytes(buf[i + 8..i + 16].try_into().ok()?) as usize
            }
            n => n,
        };
        if box_size == 0 || i + box_size > buf.len() {
            return None;
        }
        let out = (i, kind, box_size);
        i += box_size;
        Some(out)
    })
}
