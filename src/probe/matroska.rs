//! Minimal Matroska/WebM EBML reader.
//!
//! We want segment boundaries that ffmpeg's input-side `-ss` can cleanly
//! cut at with stream-copy. That means cluster starts **whose first Block
//! is a video keyframe** — files that interleave audio-only clusters
//! between video clusters would otherwise hand us audio-cluster timestamps
//! that ffmpeg can't seek to without rewinding to the previous video
//! cluster, producing overlapping HLS segments and visible skip-backs.
//!
//! We deliberately do not use the Cues index. Cues can list mid-cluster
//! keyframes whose `-ss <CueTime>` likewise rewinds to the surrounding
//! cluster start.
//!
//! The walk reads each Segment child's header, and for Clusters peeks
//! just far enough to read the Cluster.Timestamp and the first Block's
//! track+keyframe flag, then seeks past the rest of the cluster body.
//! Block payload bytes are never read.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};

const ID_EBML: u64 = 0x1A45DFA3;
const ID_SEGMENT: u64 = 0x18538067;
const ID_INFO: u64 = 0x1549A966;
const ID_TIMESTAMP_SCALE: u64 = 0x2AD7B1;
const ID_TRACKS: u64 = 0x1654AE6B;
const ID_TRACK_ENTRY: u64 = 0xAE;
const ID_TRACK_NUMBER: u64 = 0xD7;
const ID_TRACK_TYPE: u64 = 0x83;
const ID_CLUSTER: u64 = 0x1F43B675;
const ID_CLUSTER_TIMESTAMP: u64 = 0xE7;
const ID_SIMPLE_BLOCK: u64 = 0xA3;
const ID_BLOCK_GROUP: u64 = 0xA0;
const ID_BLOCK: u64 = 0xA1;
const ID_REFERENCE_BLOCK: u64 = 0xFB;
const TRACK_TYPE_VIDEO: u64 = 1;

const UNKNOWN_SIZE: u64 = u64::MAX;

/// Hard cap on any single element body we'll buffer. Real Info elements
/// are well under this; anything larger almost certainly means we've
/// misparsed and would otherwise try to allocate the whole file.
const MAX_ELEMENT_BYTES: u64 = 64 * 1024 * 1024;

/// Read sorted, deduped cluster-start times (in seconds) from a
/// Matroska/WebM file. Every cluster starts with a keyframe, so these
/// times are guaranteed ffmpeg-seekable boundaries.
pub fn read_keyframe_times(path: &Path) -> Result<Vec<f64>> {
    let mut f = File::open(path).with_context(|| format!("open {}", path.display()))?;

    let (id, size) = read_element_header(&mut f)?;
    if id != ID_EBML {
        bail!("not an EBML/Matroska file (first id 0x{:X})", id);
    }
    skip_bytes(&mut f, size)?;

    let (id, seg_size) = read_element_header(&mut f)?;
    if id != ID_SEGMENT {
        bail!("expected Segment, got 0x{:X}", id);
    }
    let seg_start = f.stream_position()?;
    let seg_end = if seg_size == UNKNOWN_SIZE {
        u64::MAX
    } else {
        seg_start.saturating_add(seg_size)
    };

    let mut timestamp_scale: u64 = 1_000_000; // ns/tick; Matroska default
    let mut video_track: Option<u64> = None;
    let mut cluster_ticks: Vec<u64> = Vec::new();

    while f.stream_position()? < seg_end {
        let (id, size) = match read_element_header(&mut f) {
            Ok(v) => v,
            Err(_) => break,
        };
        if size == UNKNOWN_SIZE {
            bail!("unknown-size top-level element 0x{:X}", id);
        }
        let body_start = f.stream_position()?;
        let body_end = body_start.saturating_add(size);
        match id {
            ID_INFO => {
                let body = read_exact_n(&mut f, size)?;
                if let Some(ts) = find_uint_child(&body, ID_TIMESTAMP_SCALE) {
                    timestamp_scale = ts;
                }
            }
            ID_TRACKS => {
                let body = read_exact_n(&mut f, size)?;
                video_track = find_video_track(&body);
            }
            ID_CLUSTER => {
                if let Some(track) = video_track {
                    if let Some(ts) = read_video_keyframe_cluster_ts(&mut f, body_end, track)? {
                        cluster_ticks.push(ts);
                    }
                }
                f.seek(SeekFrom::Start(body_end))?;
            }
            _ => {
                f.seek(SeekFrom::Start(body_end))?;
            }
        }
    }

    let _ = video_track.ok_or_else(|| anyhow!("no video track in Tracks"))?;
    if cluster_ticks.is_empty() {
        bail!("no clusters whose first block is a video keyframe");
    }
    cluster_ticks.sort_unstable();
    cluster_ticks.dedup();

    let scale_sec = timestamp_scale as f64 / 1_000_000_000.0;
    Ok(cluster_ticks
        .into_iter()
        .map(|t| t as f64 * scale_sec)
        .collect())
}

/// Walk a Tracks element body and return the TrackNumber of the first
/// TrackEntry whose TrackType is video (1). Matches ffmpeg's `-map 0:v:0`.
fn find_video_track(body: &[u8]) -> Option<u64> {
    let mut cur = body;
    while !cur.is_empty() {
        let (id, size, after) = read_header_bytes(cur)?;
        if size as usize > after.len() {
            return None;
        }
        let (elem, rest) = after.split_at(size as usize);
        if id == ID_TRACK_ENTRY
            && find_uint_child(elem, ID_TRACK_TYPE) == Some(TRACK_TYPE_VIDEO)
        {
            if let Some(num) = find_uint_child(elem, ID_TRACK_NUMBER) {
                return Some(num);
            }
        }
        cur = rest;
    }
    None
}

/// Peek into a Cluster body: read its Timestamp, then find the first
/// Block (skipping PrevSize/Position/etc), and return the cluster's
/// timestamp only if that first Block is a video keyframe on the given
/// track. Returns Ok(None) for audio-only clusters or anything we don't
/// understand, so we just skip those instead of corrupting the segment
/// list.
fn read_video_keyframe_cluster_ts(
    f: &mut File,
    body_end: u64,
    video_track: u64,
) -> Result<Option<u64>> {
    let pos = f.stream_position()?;
    if pos >= body_end {
        return Ok(None);
    }
    let (id, size) = read_element_header(f)?;
    if id != ID_CLUSTER_TIMESTAMP || size == UNKNOWN_SIZE || size > 8 {
        return Ok(None);
    }
    let mut tsbuf = [0u8; 8];
    f.read_exact(&mut tsbuf[..size as usize])?;
    let mut cluster_ts = 0u64;
    for &b in &tsbuf[..size as usize] {
        cluster_ts = (cluster_ts << 8) | b as u64;
    }

    while f.stream_position()? < body_end {
        let (bid, bsize) = match read_element_header(f) {
            Ok(v) => v,
            Err(_) => return Ok(None),
        };
        if bsize == UNKNOWN_SIZE {
            return Ok(None);
        }
        let bbody_start = f.stream_position()?;
        let bbody_end = bbody_start.saturating_add(bsize);
        match bid {
            ID_SIMPLE_BLOCK => {
                return Ok(simple_block_is_video_keyframe(f, bsize, video_track)?
                    .then_some(cluster_ts));
            }
            ID_BLOCK_GROUP => {
                let body = read_exact_n(f, bsize)?;
                return Ok(block_group_is_video_keyframe(&body, video_track)
                    .then_some(cluster_ts));
            }
            _ => {
                f.seek(SeekFrom::Start(bbody_end))?;
            }
        }
    }
    Ok(None)
}

/// SimpleBlock body layout: VINT(TrackNumber) + i16(rel_ts) + u8(flags)
/// + frame_data. Flags bit 0x80 marks a keyframe. We read only the few
/// header bytes; frame_data is skipped via seek.
fn simple_block_is_video_keyframe(
    f: &mut File,
    block_size: u64,
    video_track: u64,
) -> Result<bool> {
    let start = f.stream_position()?;
    let end = start.saturating_add(block_size);
    let mut first = [0u8; 1];
    f.read_exact(&mut first)?;
    let vint_len = (first[0].leading_zeros() + 1) as usize;
    if vint_len == 0 || vint_len > 4 {
        f.seek(SeekFrom::Start(end))?;
        return Ok(false);
    }
    let mask: u8 = if vint_len >= 8 { 0 } else { 0xFFu8 >> vint_len };
    let mut track = (first[0] & mask) as u64;
    let mut rest = [0u8; 3];
    if vint_len > 1 {
        f.read_exact(&mut rest[..vint_len - 1])?;
        for &b in &rest[..vint_len - 1] {
            track = (track << 8) | b as u64;
        }
    }
    let mut tail = [0u8; 3]; // 2 bytes rel_ts + 1 byte flags
    f.read_exact(&mut tail)?;
    let flags = tail[2];
    f.seek(SeekFrom::Start(end))?;
    Ok(track == video_track && (flags & 0x80) != 0)
}

/// BlockGroup keyframe detection: a video block in a BlockGroup is a
/// keyframe iff there is no ReferenceBlock child. We also need the inner
/// Block's track number to match the video track.
fn block_group_is_video_keyframe(body: &[u8], video_track: u64) -> bool {
    let mut block_track: Option<u64> = None;
    let mut has_reference = false;
    let mut cur = body;
    while !cur.is_empty() {
        let Some((id, size, after)) = read_header_bytes(cur) else {
            return false;
        };
        if size as usize > after.len() {
            return false;
        }
        let (elem, rest) = after.split_at(size as usize);
        match id {
            ID_BLOCK => {
                block_track = parse_block_track(elem);
            }
            ID_REFERENCE_BLOCK => {
                has_reference = true;
            }
            _ => {}
        }
        cur = rest;
    }
    block_track == Some(video_track) && !has_reference
}

fn parse_block_track(elem: &[u8]) -> Option<u64> {
    let first = *elem.first()?;
    if first == 0 {
        return None;
    }
    let len = (first.leading_zeros() + 1) as usize;
    if len == 0 || len > 4 || elem.len() < len {
        return None;
    }
    let mask: u8 = if len >= 8 { 0 } else { 0xFFu8 >> len };
    let mut val = (first & mask) as u64;
    for &b in &elem[1..len] {
        val = (val << 8) | b as u64;
    }
    Some(val)
}

fn read_element_header(f: &mut File) -> Result<(u64, u64)> {
    Ok((read_id(f)?, read_size(f)?))
}

fn read_id(f: &mut File) -> Result<u64> {
    let mut b = [0u8; 1];
    f.read_exact(&mut b)?;
    let first = b[0];
    if first == 0 {
        bail!("invalid EBML id (first byte 0)");
    }
    let len = (first.leading_zeros() + 1) as usize;
    if len > 4 {
        bail!("EBML id length {} > 4", len);
    }
    let mut val = first as u64;
    if len > 1 {
        let mut rest = [0u8; 3];
        f.read_exact(&mut rest[..len - 1])?;
        for &x in &rest[..len - 1] {
            val = (val << 8) | x as u64;
        }
    }
    Ok(val)
}

fn read_size(f: &mut File) -> Result<u64> {
    let mut b = [0u8; 1];
    f.read_exact(&mut b)?;
    let first = b[0];
    if first == 0 {
        bail!("invalid EBML size (first byte 0)");
    }
    let len = (first.leading_zeros() + 1) as usize;
    if len > 8 {
        bail!("EBML size length {} > 8", len);
    }
    let mask: u8 = if len >= 8 { 0 } else { 0xFFu8 >> len };
    let mut val = (first & mask) as u64;
    if len > 1 {
        let mut rest = [0u8; 7];
        f.read_exact(&mut rest[..len - 1])?;
        for &x in &rest[..len - 1] {
            val = (val << 8) | x as u64;
        }
    }
    let bits = 7 * len as u32;
    let all_ones: u64 = if bits >= 64 { u64::MAX } else { (1u64 << bits) - 1 };
    Ok(if val == all_ones { UNKNOWN_SIZE } else { val })
}

fn read_exact_n(f: &mut File, n: u64) -> Result<Vec<u8>> {
    if n > MAX_ELEMENT_BYTES {
        bail!("element size {n} exceeds {MAX_ELEMENT_BYTES} byte sanity cap");
    }
    let mut buf = vec![0u8; n as usize];
    f.read_exact(&mut buf)?;
    Ok(buf)
}

fn skip_bytes(f: &mut File, n: u64) -> Result<()> {
    let pos = f.stream_position()?;
    f.seek(SeekFrom::Start(pos.saturating_add(n)))?;
    Ok(())
}


/// Find the first child with the given id and parse its body as a
/// big-endian unsigned integer.
fn find_uint_child(body: &[u8], target_id: u64) -> Option<u64> {
    let mut cur = body;
    while !cur.is_empty() {
        let (id, size, after) = read_header_bytes(cur)?;
        if size as usize > after.len() {
            return None;
        }
        let (elem, rest) = after.split_at(size as usize);
        if id == target_id {
            return Some(parse_uint(elem));
        }
        cur = rest;
    }
    None
}

fn parse_uint(bytes: &[u8]) -> u64 {
    let mut v = 0u64;
    for &b in bytes.iter().take(8) {
        v = (v << 8) | b as u64;
    }
    v
}

fn read_header_bytes(buf: &[u8]) -> Option<(u64, u64, &[u8])> {
    let (id, after_id) = read_id_bytes(buf)?;
    let (size, after_size) = read_size_bytes(after_id)?;
    Some((id, size, after_size))
}

fn read_id_bytes(buf: &[u8]) -> Option<(u64, &[u8])> {
    let first = *buf.first()?;
    if first == 0 {
        return None;
    }
    let len = (first.leading_zeros() + 1) as usize;
    if len > 4 || buf.len() < len {
        return None;
    }
    let mut val = 0u64;
    for &b in &buf[..len] {
        val = (val << 8) | b as u64;
    }
    Some((val, &buf[len..]))
}

fn read_size_bytes(buf: &[u8]) -> Option<(u64, &[u8])> {
    let first = *buf.first()?;
    if first == 0 {
        return None;
    }
    let len = (first.leading_zeros() + 1) as usize;
    if len > 8 || buf.len() < len {
        return None;
    }
    let mask: u8 = if len >= 8 { 0 } else { 0xFFu8 >> len };
    let mut val = (first & mask) as u64;
    for &b in &buf[1..len] {
        val = (val << 8) | b as u64;
    }
    Some((val, &buf[len..]))
}
