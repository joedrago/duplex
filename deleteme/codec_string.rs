//! WebCodecs / MSE codec strings derived from ffprobe stream metadata.
//!
//! Used by `/api/manifest` so the client can call `VideoDecoder.isConfigSupported`
//! with a precise string before bothering to decode a single frame.

use crate::probe::Stream;

/// Codec string for the video stream's WebCodecs config (`avc1.*`, `hev1.*`, …).
/// Falls back to a best-effort guess when ffprobe couldn't read profile/level.
pub fn video_codec_string(stream: &Stream) -> Option<String> {
    let codec = stream.codec_name.as_deref()?;
    Some(match codec {
        "h264" => avc1_string(stream.profile.as_deref(), stream.level),
        "hevc" => hvc1_string(stream.profile.as_deref(), stream.level),
        "av1" => av1_string(stream.profile.as_deref(), stream.level),
        "vp9" => vp9_string(stream.profile.as_deref(), stream.level),
        other => other.to_string(),
    })
}

/// Codec string for the audio stream. Only AAC has a well-defined MIME-style
/// string in common use; for ac3/eac3/opus/flac WebCodecs accepts the bare
/// codec name as the `codec` field, so we return that.
pub fn audio_codec_string(stream: &Stream) -> Option<String> {
    let codec = stream.codec_name.as_deref()?;
    Some(match codec {
        "aac" => "mp4a.40.2".to_string(),
        "ac3" => "ac-3".to_string(),
        "eac3" => "ec-3".to_string(),
        "opus" => "opus".to_string(),
        "flac" => "flac".to_string(),
        "mp3" => "mp3".to_string(),
        other => other.to_string(),
    })
}

// avc1.PPCCLL — PP = profile_idc (hex), CC = profile compatibility flags
// (we don't have these from ffprobe without parsing the SPS, so use 0x00),
// LL = level_idc (hex). ffprobe surfaces profile as a human string and level
// as the integer level_idc value (e.g. 41 for level 4.1 → 0x29).
pub fn avc1_string(profile: Option<&str>, level: Option<i32>) -> String {
    let profile_idc = match profile.unwrap_or("") {
        "Constrained Baseline" | "Baseline" => 66,
        "Main" => 77,
        "Extended" => 88,
        "High" => 100,
        "High 10" | "High 10 Intra" => 110,
        "High 4:2:2" | "High 4:2:2 Intra" => 122,
        "High 4:4:4 Predictive" | "High 4:4:4 Intra" | "High 4:4:4" => 244,
        _ => 100,
    };
    let level_idc = level.unwrap_or(31) as u32;
    format!("avc1.{:02x}00{:02x}", profile_idc, level_idc)
}

// hvc1.<gps><pi>.<compat>.<tier><li>.<constraints> — without parsing the
// HEVC VPS/SPS we can only build a best-effort string from profile + level.
// ffprobe reports HEVC level as level_idc (e.g. 120 = level 4.0, 150 = level
// 5.0); the codec-string form just embeds that as the L-suffix integer.
pub fn hvc1_string(profile: Option<&str>, level: Option<i32>) -> String {
    let (profile_idc, compat) = match profile.unwrap_or("") {
        "Main 10" => (2, "4"),
        _ => (1, "6"),
    };
    let level_idc = level.unwrap_or(120);
    format!("hvc1.{profile_idc}.{compat}.L{level_idc}.B0")
}

// av01.<profile>.<level><tier>.<bitDepth>[.<rest>] — bare-minimum string the
// browser will accept. Without sequence-header inspection we can only guess
// the bit depth; default to 8 ("08"). Mediabunny supplies a precise string at
// decode time, so this is only used for the manifest hint.
fn av1_string(profile: Option<&str>, level: Option<i32>) -> String {
    let p = match profile.unwrap_or("") {
        "Professional" => 2,
        "High" => 1,
        _ => 0,
    };
    let lv = level.unwrap_or(0);
    format!("av01.{p}.{:02}M.08", lv)
}

// vp09.<profile>.<level>.<bitDepth>[.<rest>] — same hand-wave as AV1.
fn vp9_string(profile: Option<&str>, _level: Option<i32>) -> String {
    let p = match profile.unwrap_or("") {
        "Profile 1" => 1,
        "Profile 2" => 2,
        "Profile 3" => 3,
        _ => 0,
    };
    format!("vp09.{:02}.10.08", p)
}
