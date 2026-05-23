//! ffmpeg subprocess helpers.
//!
//! The HLS hot path now lives in `crate::stream`, which runs a single
//! long-lived ffmpeg per session. This module is left with the two
//! subtitle-extraction streamers used by the `subs` endpoint.

use std::path::Path;
use std::process::Stdio;

use bytes::Bytes;
use futures::stream::Stream;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio_util::io::ReaderStream;

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
        use futures::StreamExt as _;
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
