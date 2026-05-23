//! Minimal Matroska/WebM EBML reader.
//!
//! We need a list of times where ffmpeg's input-side `-ss <X>` can cleanly
//! cut for stream-copy. Those are the **first-keyframe PTS of each cluster
//! that contains video**, in the file's own Cues index — because ffmpeg's
//! seek consults Cues by exact `CueTime`, and only times present in Cues
//! seek precisely (any other value rounds *down* to the previous cue,
//! which lands in the wrong cluster).
//!
//! Algorithm: walk Segment children, parse `Info > TimestampScale` and the
//! full `Cues` body. For each video CuePoint, group by `CueClusterPosition`
//! and keep the minimum CueTime per group — that's the cluster's first
//! video keyframe.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};

const ID_EBML: u64 = 0x1A45DFA3;
const ID_SEGMENT: u64 = 0x18538067;
const ID_SEEK_HEAD: u64 = 0x114D9B74;
const ID_SEEK: u64 = 0x4DBB;
const ID_SEEK_ID: u64 = 0x53AB;
const ID_SEEK_POSITION: u64 = 0x53AC;
const ID_INFO: u64 = 0x1549A966;
const ID_TIMESTAMP_SCALE: u64 = 0x2AD7B1;
const ID_TRACKS: u64 = 0x1654AE6B;
const ID_TRACK_ENTRY: u64 = 0xAE;
const ID_TRACK_NUMBER: u64 = 0xD7;
const ID_TRACK_TYPE: u64 = 0x83;
const ID_CLUSTER: u64 = 0x1F43B675;
const ID_CUES: u64 = 0x1C53BB6B;
const ID_CUE_POINT: u64 = 0xBB;
const ID_CUE_TIME: u64 = 0xB3;
const ID_CUE_TRACK_POSITIONS: u64 = 0xB7;
const ID_CUE_TRACK: u64 = 0xF7;
const ID_CUE_CLUSTER_POSITION: u64 = 0xF1;
const TRACK_TYPE_VIDEO: u64 = 1;

const UNKNOWN_SIZE: u64 = u64::MAX;

/// Hard cap on any single element body we'll buffer. Real Info / Cues
/// elements are well under this; anything larger almost certainly means
/// we've misparsed and would otherwise try to allocate the whole file.
const MAX_ELEMENT_BYTES: u64 = 64 * 1024 * 1024;

/// Read sorted, deduped video keyframe times (in seconds) from a
/// Matroska/WebM file by reading its Cues index and taking the first
/// CueTime per cluster.
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
    let mut cues_body: Option<Vec<u8>> = None;
    let mut cues_offset: Option<u64> = None;

    // Walk Segment children only until we hit a Cluster. Cues is usually at
    // the end of the file; a SeekHead near the start tells us where, so we
    // don't have to skip past every cluster body to find it.
    while f.stream_position()? < seg_end {
        let (id, size) = match read_element_header(&mut f) {
            Ok(v) => v,
            Err(_) => break,
        };
        if size == UNKNOWN_SIZE {
            // Streamable cluster or similar — bail to the SeekHead-driven path below.
            break;
        }
        let body_start = f.stream_position()?;
        let body_end = body_start.saturating_add(size);
        match id {
            ID_SEEK_HEAD => {
                let body = read_exact_n(&mut f, size)?;
                if let Some(rel) = find_seek_position(&body, ID_CUES) {
                    cues_offset = Some(seg_start.saturating_add(rel));
                }
            }
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
            ID_CUES => {
                cues_body = Some(read_exact_n(&mut f, size)?);
                break;
            }
            ID_CLUSTER => {
                // Cluster data starts. Anything we still need (Cues, possibly
                // Info/Tracks if the file is unusually ordered) must be
                // reached via SeekHead.
                break;
            }
            _ => {
                f.seek(SeekFrom::Start(body_end))?;
            }
        }
    }

    // If we didn't already capture Cues inline, jump to the offset SeekHead
    // gave us.
    if cues_body.is_none() {
        let off = cues_offset.ok_or_else(|| anyhow!("no Cues element"))?;
        f.seek(SeekFrom::Start(off))?;
        let (id, size) = read_element_header(&mut f)?;
        if id != ID_CUES {
            bail!("SeekHead pointed to 0x{:X}, not Cues", id);
        }
        if size == UNKNOWN_SIZE {
            bail!("Cues element has unknown size");
        }
        cues_body = Some(read_exact_n(&mut f, size)?);
    }

    let body = cues_body.expect("cues_body checked above");
    let track = video_track.ok_or_else(|| anyhow!("no video track in Tracks"))?;
    let mut min_per_cluster = first_keyframe_per_cluster(&body, track);
    min_per_cluster.sort_unstable();
    min_per_cluster.dedup();

    let scale_sec = timestamp_scale as f64 / 1_000_000_000.0;
    Ok(min_per_cluster
        .into_iter()
        .map(|t| t as f64 * scale_sec)
        .collect())
}

/// Walk a SeekHead body and return the SeekPosition (relative to Segment
/// data start) of the first Seek entry whose SeekID matches `target_id`.
fn find_seek_position(body: &[u8], target_id: u64) -> Option<u64> {
    let mut cur = body;
    while !cur.is_empty() {
        let (id, size, after) = read_header_bytes(cur)?;
        if size as usize > after.len() {
            return None;
        }
        let (elem, rest) = after.split_at(size as usize);
        if id == ID_SEEK {
            let seek_id_bytes = find_binary_child(elem, ID_SEEK_ID)?;
            let seek_pos = find_uint_child(elem, ID_SEEK_POSITION)?;
            if parse_uint(seek_id_bytes) == target_id {
                return Some(seek_pos);
            }
        }
        cur = rest;
    }
    None
}

fn find_binary_child<'a>(body: &'a [u8], target_id: u64) -> Option<&'a [u8]> {
    let mut cur = body;
    while !cur.is_empty() {
        let (id, size, after) = read_header_bytes(cur)?;
        if size as usize > after.len() {
            return None;
        }
        let (elem, rest) = after.split_at(size as usize);
        if id == target_id {
            return Some(elem);
        }
        cur = rest;
    }
    None
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

/// For each CuePoint in `body` whose CueTrackPositions references `track`,
/// emit one (cluster_position, cue_time) pair. Then collapse to the
/// minimum cue_time per cluster_position — that's the first-keyframe time
/// for that cluster.
fn first_keyframe_per_cluster(body: &[u8], track: u64) -> Vec<u64> {
    use std::collections::HashMap;
    let mut by_cluster: HashMap<u64, u64> = HashMap::new();
    let mut cur = body;
    while !cur.is_empty() {
        let Some((id, size, after)) = read_header_bytes(cur) else {
            break;
        };
        if size as usize > after.len() {
            break;
        }
        let (elem, rest) = after.split_at(size as usize);
        if id == ID_CUE_POINT {
            if let (Some(time), Some(cluster_pos)) =
                (find_uint_child(elem, ID_CUE_TIME), cue_cluster_for_track(elem, track))
            {
                by_cluster
                    .entry(cluster_pos)
                    .and_modify(|t| {
                        if time < *t {
                            *t = time;
                        }
                    })
                    .or_insert(time);
            }
        }
        cur = rest;
    }
    by_cluster.into_values().collect()
}

/// In a CuePoint body, find the CueClusterPosition associated with the
/// CueTrackPositions for `track`. Returns None if no such position exists.
fn cue_cluster_for_track(elem: &[u8], track: u64) -> Option<u64> {
    let mut cur = elem;
    while !cur.is_empty() {
        let (id, size, after) = read_header_bytes(cur)?;
        if size as usize > after.len() {
            return None;
        }
        let (sub, rest) = after.split_at(size as usize);
        if id == ID_CUE_TRACK_POSITIONS
            && find_uint_child(sub, ID_CUE_TRACK) == Some(track)
        {
            return find_uint_child(sub, ID_CUE_CLUSTER_POSITION);
        }
        cur = rest;
    }
    None
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
