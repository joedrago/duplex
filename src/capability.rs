//! Deterministic playback-decision logic.
//!
//! Given a probe result and a client capability matrix, decide whether the
//! file can be DirectPlayed, HLS-remuxed (video copy, audio copy), HLS-remuxed
//! with audio transcoded to AAC, or whether playback is unsupported.

use std::collections::HashSet;

use serde::Serialize;

use crate::probe::Probe;

#[derive(Debug, Clone)]
pub struct Capabilities {
    pub video_codecs: HashSet<&'static str>,
    pub audio_codecs: HashSet<&'static str>,
    /// Containers playable directly via `<video src>`.
    pub direct_containers: HashSet<&'static str>,
}

pub fn default_caps() -> Capabilities {
    Capabilities {
        video_codecs: ["h264", "hevc"].into_iter().collect(),
        // AAC-only for HLS-fMP4: ac3/eac3 in fragmented MP4 with `-c:a copy`
        // hits ffmpeg muxer quirks ("codec frame size is not set") that
        // produce init segments MSE rejects. Anything else gets transcoded
        // to stereo AAC via the HlsAudioTranscode path.
        audio_codecs: ["aac"].into_iter().collect(),
        direct_containers: ["mp4", "m4v", "mov"].into_iter().collect(),
    }
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub enum Decision {
    DirectPlay,
    HlsCopy,
    HlsAudioTranscode,
    Unsupported,
}

impl Decision {
    pub fn label(&self) -> String {
        match self {
            Decision::DirectPlay => "direct",
            Decision::HlsCopy => "hls",
            Decision::HlsAudioTranscode => "hls-audio-transcode",
            Decision::Unsupported => "unsupported",
        }
        .to_string()
    }
}

pub fn decide(probe: &Probe, caps: &Capabilities) -> Decision {
    let Some(v) = probe.video_stream() else {
        return Decision::Unsupported;
    };
    let Some(vc) = v.codec_name.as_deref() else {
        return Decision::Unsupported;
    };
    if !caps.video_codecs.contains(vc) {
        return Decision::Unsupported;
    }

    let any_audio_compat = probe.audio_streams().any(|a| {
        a.codec_name
            .as_deref()
            .map(|c| caps.audio_codecs.contains(c))
            .unwrap_or(false)
    });

    // Container check: ffprobe reports "mov,mp4,m4a,3gp,3g2,mj2" for the MP4
    // family; we accept any token that's in our direct list.
    let format_name = probe.format.format_name.split(',').collect::<Vec<_>>();
    let container_direct = format_name
        .iter()
        .any(|f| caps.direct_containers.contains(*f));

    if container_direct && any_audio_compat {
        Decision::DirectPlay
    } else if any_audio_compat {
        Decision::HlsCopy
    } else {
        // Video compatible but no audio track is — transcode audio.
        Decision::HlsAudioTranscode
    }
}
