# Duplex — Plan

The original long-form v1 plan described a server-side HLS / fragmented-MP4
pipeline with rsmpeg-driven remux + AAC re-encode. That stack has been
deleted in favor of a **fully client-side player** using Mediabunny +
WebCodecs. The current architecture is summarized in [`README.md`](README.md);
the implementation plan that drove this rewrite lives at
`~/.claude/plans/noble-swimming-scott.md`.

## What the server does now

- Scans configured `--library` roots, watches them via `notify`, holds the
  tree in an `arc-swap` snapshot.
- Lazily probes files with `ffprobe` on first inspection; caches the JSON.
- Exposes:
    - `GET /api/browse?path=…` — directory listing.
    - `GET /api/manifest?path=…` — slim track list (video/audio/subtitle),
      sidecar URLs, codec strings for the WebCodecs precheck.
    - `GET /api/raw?path=…` — range-aware byte serving.
    - `GET /api/sidecar?path=…&index=N` — raw sidecar subtitle bytes.
    - `GET /api/recent`, `GET /api/next?path=…` — browse helpers.
    - `POST /_debug/log` (gated by `--js-logs`) — mirror browser console
      into server stdout.
- Serves the embedded static client (rust-embed) with COOP/COEP/CORP headers
  so the page is `crossOriginIsolated` and threaded WASM works.
- Does **no** ffmpeg subprocess work at playback time. The only subprocess
  it spawns is `ffprobe`, once per file (cached), for browse + manifest.

## What the client does

`web/player.js`:

- Opens a Mediabunny `Input` over `/api/raw` via ranged fetches.
- Reads the primary video track and a user-chosen audio track ordinal.
- Drives WebCodecs `VideoDecoder` → `<canvas>`, `AudioDecoder` →
  `AudioContext`-scheduled buffer sources (master clock).
- Downmixes 5.1 / 7.1 / arbitrary layouts to stereo via ITU-R coefficients
  so dialogue (center channel) is audible everywhere.
- Three backpressure gates per pump: output queue, decoder `decodeQueueSize`,
  scheduled-audio lookahead. Without all three the decoders silently race
  ahead and the AudioContext drowns in tens of thousands of pending sources.
- Seeks: rebase the clock synchronously, abort pumps, `decoder.reset()` +
  `configure()` (NOT `flush()` — that emits stale frames that block the
  present loop), seed the new pump from the prior keyframe.
- Sidecar subtitles fetched + parsed in JS. Format dispatch sniffs content
  (WebVTT header, ASS `[Script Info]`, SubViewer `[INFORMATION]`); supports
  VTT, SRT, ASS-as-plain-text, SubViewer.
- Tap-to-play overlay when `audioCtx` boots suspended (autoplay policy).
- Audio button shows 🔇 + `— unsupported` labels when WebCodecs can't decode
  the chosen track (AC-3 / E-AC-3 in Chrome without Dolby).

## What's deferred ("future fun")

- Embedded text subtitle reading (mov_text / subrip / ASS in MP4/MKV) —
  Mediabunny doesn't currently expose subtitle tracks; would need a small
  JS subtitle-track demuxer or the same in WASM.
- ASS rendering with styling (fonts, positioning, karaoke) — JASSUB is the
  drop-in dependency.
- PGS / VobSub image subtitle rendering — libbitsub / pgs-wasm.
- AC-3 / E-AC-3 in-browser decode for non-Dolby Chrome builds — ffmpeg.wasm
  audio-only would work.
- AV1 fallback for older Intel Macs that can't hardware-decode.
- Native tvOS client (the old `tvos/` WKWebView shell is out of scope).
