# Duplex — Plan

A small, opinionated media server. Single Rust binary, a thin web client, a tvOS WebView shell. The library on disk is the source of truth; the server treats it as read-only and reflects it as-is. Files are served either directly (when natively playable) or via on-the-fly HLS that remuxes containers and, when necessary, transcodes audio to AAC. Video is never transcoded.

This document is the design we'd build from. It is intentionally specific enough to start work without further design, but does not prescribe implementation details that are better decided at coding time.

---

## Goals

- **Read-only library**: server never writes into the library directory. Ever.
- **Zero on-disk cache (v1)**: all derived state lives in memory. Restart = cold; that's fine.
- **Trivial local dev**: `cargo run -- /path/to/some/videos` and a browser at `localhost:8080` works.
- **Web and tvOS as first-class targets**, sharing one player (the web client; tvOS wraps it in WKWebView).
- **Browse mirrors disk**: directory and file basenames are the UI. Add/rename/move/rm on disk and the server reflects it within seconds.
- **Predictable rules, no magic**: server decisions (direct play vs HLS vs unsupported) are deterministic from probe results and a small client-capability matrix.
- **Auditable in an afternoon**: target a few thousand lines of Rust plus a few hundred of JS.

## Non-goals (v1)

- No transcoding of video. Files with incompatible video codecs are surfaced as such; the user fixes it at the source if they care.
- No accounts, no watch-progress, no resume, no "recently watched."
- No metadata scraping (TMDB, posters from internet, etc.). One auto-extracted JPEG per file is fine.
- No image-based subtitles (PGS, VobSub, DVDSub). Inventoried but marked unsupported.
- No on-disk cache, no transcoding queue, no background workers beyond the filesystem watcher.
- No multi-user, no remote access concerns, no auth. LAN-only is assumed.
- No adaptive bitrate. One video rendition per file, always the original.

## Architectural shape

```
┌────────────────────────────────────────────────────────────────┐
│                       Library (read-only)                      │
│        /media/Movies/...    /media/TV/...    *.srt  *.vtt      │
└────────────────────────────────────────────────────────────────┘
                                │
                          fs scan + watch
                                │
                                ▼
┌────────────────────────────────────────────────────────────────┐
│                        Duplex (Rust)                           │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────┐    │
│  │  Library    │  │   Probe      │  │   ffmpeg driver     │    │
│  │  (in-mem    │  │   (lazy,     │  │   (subprocess in    │    │
│  │   tree)     │  │   cached)    │  │   v1, in-proc TBD)  │    │
│  └─────────────┘  └──────────────┘  └─────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │           HTTP server (axum / tokio)                    │   │
│  │   /api/browse   /api/file   /api/raw   /api/play/...    │   │
│  │   /api/poster   /            (web client + assets)      │   │
│  └─────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
                                │
                                ▼
           ┌──────────────────┐         ┌─────────────────┐
           │   Web client     │         │ tvOS WKWebView  │
           │  (vanilla JS +   │         │   shell (steals │
           │     hls.js)      │         │   movienight)   │
           └──────────────────┘         └─────────────────┘
```

The server is the only piece with logic. The web client is a thin browse + player. The tvOS app is a thinner shell around the web client.

## Repository layout

```
duplex/
  Cargo.toml
  src/
    main.rs              entry + CLI/env
    config.rs            resolved settings
    library/
      mod.rs             tree model
      scan.rs            initial walk
      watcher.rs         notify-rs filesystem events
    probe/
      mod.rs             ffprobe JSON wrapping
      keyframes.rs       keyframe time extraction
      subs.rs            sidecar discovery + embedded text-sub inventory
    capability.rs        client capability matrix + decision logic
    api/
      mod.rs             axum router
      browse.rs
      file.rs
      raw.rs             range-served pass-through
      hls.rs             master + media playlists, segment endpoint
      subs.rs            on-demand WebVTT
      poster.rs
      web.rs             embedded web client (rust-embed)
    ffmpeg/
      mod.rs             trait + subprocess impl
      segment.rs         remux a [start, start+dur] slice to fMP4
      audio.rs           AAC stereo re-encode of one audio track
      subs.rs            srt/ass/mov_text → webvtt
  web/
    index.html
    app.js
    style.css
    vendor/hls.min.js
  tvos/
    Makefile             ported from movienight
    project.yml          xcodegen
    Sources/
      AppDelegate.swift
      WebViewController.swift
      Info.plist
  Dockerfile             multi-stage, ffmpeg in runtime image
  docker-compose.example.yml
  README.md
  PLAN.md                this file
```

## Library model

A `Library` is a tree rooted at the configured directory. Each node is either a `Directory { name, children }` or a `File { name, path, ext, size, mtime, probe: OnceCell<ProbeResult> }`.

- Scan at startup with `walkdir`, ignoring dotfiles and a small extension allowlist for video (`mp4`, `mkv`, `mov`, `webm`, `m4v`) and subtitle (`srt`, `vtt`, `ass`) files.
- Files keep their sibling subtitles attached as a `Vec<SidecarSub>` resolved by basename match (with optional language suffix: `Movie.en.srt`).
- Probe is lazy: filled when an API request first needs it, then cached in the `OnceCell`. Invalidated (reset to `None`) when the watcher reports an mtime/size change.
- The tree is held behind an `RwLock` (or `arc-swap`d if we want lock-free reads). Reads are the hot path.
- Filesystem watcher (`notify` crate) batches events and applies them to the tree: add file, remove file, rename, mtime-change.

Browse responses are computed from this tree with no I/O.

## Probe data

What we extract via `ffprobe -of json` per file (one shot):

- Container, duration, bit rate, size.
- Per stream: index, codec, profile, level, language tag, channel layout (audio), pixel format and color info (video), default/forced flags (subs), `codec_type`.
- Keyframe timestamps: separate ffprobe call with `-skip_frame nokey -show_entries packet=pts_time -select_streams v:0`. Done once on first HLS request, cached.

Probe results are a plain serializable struct so we can show them in `/api/file` for debugging.

## Capability decision

A `Capabilities` struct defines what the client claims it can play:

```
video_codecs:  { h264, hevc }       // default; extensible
audio_codecs:  { aac, ac3, eac3 }   // configurable per client
containers:    { mp4, fmp4_hls }
max_video:     { width, height, profile, level }
```

For a given file + capabilities, the server picks one of:

- **DirectPlay**: container is MP4-family, all selected streams are in `video_codecs` ∪ `audio_codecs`. Served via `/api/raw` with `Range` support. Native `<video src>` consumes it.
- **HLS-remux**: video is compatible but container isn't (e.g. MKV/H.264/AAC). Generate playlist; segments are `-c:v copy -c:a copy` slices.
- **HLS-remux + audio transcode**: video is compatible, audio isn't (e.g. MKV/HEVC/EAC-3 to a client that lacks EAC-3). Segments are `-c:v copy -c:a aac -b:a 192k -ac 2`. Cheap.
- **Unsupported**: video codec not in `video_codecs`. UI shows the file with a "won't play on this device — codec X" badge. No transcode. No fallback.

The capability matrix is sent by the client at session start (`POST /api/session` returning a session id, or just included as a query param on every request — leaning toward the latter for statelessness). Sensible default targets modern Safari + tvOS.

## HTTP API

All API paths are versioned-less in v1. JSON for metadata, HLS/MP4 bytes for media.

### Browsing & metadata

| Method | Path                             | Notes                                                                                         |
| ------ | -------------------------------- | --------------------------------------------------------------------------------------------- |
| `GET`  | `/api/browse?path=Movies/Action` | One directory listing. Returns `{ path, entries: [{ name, kind, ... }] }`. No recursion.      |
| `GET`  | `/api/file?path=...`             | Probe info + capability decision for the configured client. Drives the player UI.             |
| `GET`  | `/api/poster?path=...`           | JPEG, extracted on demand from one frame near 10% into the file. Streamed from ffmpeg stdout. |

### Direct play

| Method | Path                | Notes                                                                                             |
| ------ | ------------------- | ------------------------------------------------------------------------------------------------- |
| `GET`  | `/api/raw?path=...` | Range-aware passthrough of the original file bytes. Only offered when the decision is DirectPlay. |

### HLS

| Method | Path                                  | Notes                                                                                                                                                                      |
| ------ | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET`  | `/api/play/<path>/master.m3u8`        | Master playlist. Lists the single video rendition and one media playlist per compatible audio track + each text subtitle.                                                  |
| `GET`  | `/api/play/<path>/v/index.m3u8`       | Video media playlist. EXTINF values derived from keyframe deltas.                                                                                                          |
| `GET`  | `/api/play/<path>/v/<n>.m4s`          | Video segment N. Spawns ffmpeg with `-ss <kf_time> -t <dur> -c:v copy -f mp4 -movflags +frag_keyframe+empty_moov+default_base_moof -`. Streams stdout to the response.     |
| `GET`  | `/api/play/<path>/a/<idx>/index.m3u8` | Audio media playlist for source audio stream `idx`.                                                                                                                        |
| `GET`  | `/api/play/<path>/a/<idx>/<n>.m4s`    | Audio segment. `-c:a copy` if compatible, otherwise `-c:a aac -ac 2 -b:a 192k`.                                                                                            |
| `GET`  | `/api/play/<path>/s/<idx>.vtt`        | Subtitle stream `idx` as a single WebVTT file. (HLS technically wants subs segmented; we serve them as one segment covering the whole duration, which all players accept.) |

The `<path>` segment in URLs is URL-encoded but preserves slashes so HLS players resolve relative segment URLs naturally.

## Subtitles

On probe, we build a unified list of `SubtitleTrack { id, source, language, format, label }` per file:

- **Sidecar**: any `.srt`/`.vtt`/`.ass` adjacent to the file with matching basename. Language inferred from filename suffix (`.en.srt`).
- **Embedded text**: streams reported by ffprobe with codec in `{ subrip, ass, ssa, mov_text, webvtt }`.
- **Embedded image**: inventoried but flagged `format: image`; never offered, surfaced in `/api/file` only for diagnostics.

When requested:

- Sidecar `.vtt`: served as-is.
- Sidecar `.srt`: piped through ffmpeg (`-f srt -i - -f webvtt -`) and streamed out. Fast.
- Embedded text: `ffmpeg -i <file> -map 0:s:<idx> -f webvtt -`.

ASS styling is intentionally lossy in this path (downconvert to plain WebVTT). Anyone who cares about karaoke subs is using a different tool.

## ffmpeg integration

**v1: subprocess.** `tokio::process::Command`, stream stdout into the HTTP response body. Per-segment ffmpeg startup is ~50ms; segments are ~10s of media; cost is negligible.

**Why not in-process bindings?** The `ffmpeg-next` / `rust-ffmpeg` crates exist and work, but: build complexity (needs ffmpeg dev headers in the right place), API surface to learn, harder cross-compilation for the Docker image. A subprocess gives us the exact same capability, trivially debuggable (just print the command line), and we can hot-swap ffmpeg builds independently of the binary.

The `ffmpeg` module is built behind a trait so we can swap to in-process later if profiling justifies it. Decide that with data, not speculation.

## Filesystem watcher

`notify` crate with debouncing (~250ms). On events:

- **Create/modify file**: insert or invalidate probe cache. New files appear in browse responses immediately.
- **Remove**: drop from tree. Any in-flight HLS sessions for that file will fail naturally on the next segment request; clients show an error.
- **Rename**: handled as remove + create.
- **Directory add/remove**: rescan that directory subtree.

Probe results are keyed on `(path, mtime, size)` so a modification cleanly invalidates them.

## Web client

One HTML page, vanilla JS, hash routing. No framework. ~500 lines of JS goal.

- `#/browse/<path>`: ask `/api/browse`, render a list. Folders are bigger tiles, files show poster + duration + a quality badge if HEVC.
- `#/play/<path>`: ask `/api/file`, render a `<video>` plus controls:
    - If DirectPlay: set `src` to `/api/raw?path=...`.
    - Otherwise: load `/api/play/<path>/master.m3u8` via hls.js (or natively in Safari).
    - Subtitle dropdown lists available WebVTT tracks; selecting one adds `<track src=...>` or swaps via hls.js subtitle API.
    - Audio dropdown switches HLS audio rendition.
- A small "details" panel shows codecs, container, audio tracks, why playback is direct/remux/etc. Useful for debugging and for the user to learn what their library actually contains.

Static assets are embedded into the Rust binary via `rust-embed` so deployment is one file plus ffmpeg.

## tvOS app

Lifted directly from `/Users/joe/work/movienight/tvos`:

- `Makefile` + `xcodegen project.yml` + a couple of Swift files.
- `make build WEBVIEW_URL=http://duplex.lan:8080`
- `make install` for sideloading to an Apple TV.
- WKWebView pointed at the server's root URL. The web client does everything; the shell exists only to host it and to bridge the Siri Remote touchpad to pointer events.

Bundle identifier and naming are project-local; nothing reaches back into the movienight repo at build time.

## Docker packaging

Pattern follows `/Users/joe/work/whatsync/Dockerfile` (multi-stage). Two stages:

1. **Builder**: `rust:slim-bookworm`, `cargo build --release`.
2. **Runtime**: `debian:bookworm-slim` + `ffmpeg` package + the binary. Library mounted read-only into the container at a known path (`/media`). Single `EXPOSE 8080`.

`docker-compose.example.yml`:

```yaml
services:
    duplex:
        build: .
        container_name: duplex
        restart: unless-stopped
        ports:
            - "8080:8080"
        volumes:
            - /path/to/library:/media:ro
        environment:
            DUPLEX_LIBRARY: /media
            DUPLEX_BIND: 0.0.0.0:8080
```

## Configuration

CLI flags (preferred for local dev) backed by env vars (preferred in Docker):

- `--library PATH` / `DUPLEX_LIBRARY` — required. Read-only library root.
- `--bind ADDR` / `DUPLEX_BIND` — default `127.0.0.1:8080`.
- `--log LEVEL` / `DUPLEX_LOG` — default `info`.
- `--ffmpeg PATH` / `DUPLEX_FFMPEG` — default looks on `$PATH`.

No config file in v1. Everything is a flag/env.

## Build phases

Each phase ends with something demonstrable.

1. **Skeleton + browse.** Cargo project, axum server, library scan, watcher, `/api/browse`, embedded placeholder web client that lists files. No playback yet. Run locally on a test directory; see the tree in a browser.
2. **Direct play.** Probe, capability decision, `/api/raw` with range support. Web client plays DirectPlay-eligible files via `<video src>`. MP4 files just work.
3. **HLS for compatible-video files.** Keyframe extraction, master + media playlists, `-c copy` segment endpoint. MKVs with H.264+AAC start playing on Safari and via hls.js. Seeking works.
4. **Audio transcode path.** Detect incompatible audio, switch the audio rendition to `-c:a aac -ac 2`. EAC-3/DTS-bearing MKVs become playable.
5. **Subtitles.** Sidecar discovery during scan, embedded text-sub inventory during probe, WebVTT endpoint. Web client surfaces them in a dropdown.
6. **Posters.** On-demand JPEG extraction; browse view shows them.
7. **tvOS shell.** Port the movienight Makefile + xcodegen + WKWebView controller. Verify playback on real hardware.
8. **Docker.** Dockerfile, compose example, NAS deploy.

Phases 1–5 are the core; everything else is finish.

## Open questions to resolve in code

- **Concurrent segment requests.** When the user seeks, hls.js issues several segment requests in quick succession. Each spawns an ffmpeg. Is parallelism fine, or do we need a per-file semaphore? Default: let them run in parallel; measure.
- **Keyframe density.** Some sources have sparse keyframes (10+ second GOPs). Segment durations follow keyframes, so we may end up with 15-second segments. Acceptable for v1; revisit if seeking feels chunky.
- **Path escaping in URLs.** Confirm hls.js handles parens/spaces in segment URLs correctly. Encode aggressively if not.
- **HEVC Main 10 (10-bit).** Include in default `video_codecs` and let the player fail on devices that can't handle it, or split out as a separate capability? Lean toward the former — Apple devices handle it, and the user picked their devices.
- **In-flight session cleanup.** If a client navigates away mid-playback, ffmpeg processes for outstanding segment requests should be killed when the response body is dropped. Axum + tokio handle this via cancellation; verify it actually works.
- **CORS.** Single-origin in normal use, but the dev workflow might run the web client from a different port. Permissive CORS in `--dev` mode, locked down by default.
- **What does "unsupported" look like in the UI.** A greyed tile with the codec name in a badge? A modal explaining what's wrong? Decide when building the browse view.

## What this plan deliberately doesn't include

- An on-disk cache. If profiling shows that re-segmenting the same range repeatedly is hurting us, add a small LRU cache later. Don't pre-build it.
- A "scan progress" UI. The scan is fast enough on a NAS that startup latency is invisible. If it isn't, revisit.
- Transcoding of any kind for video. This is a hard rule, not a v1 punt.
- Plugin architecture, theming, multi-library support, user accounts, anything that smells like Plex. The point of this project is that it is small.

## Success criteria for v1

- `cargo run -- ~/Movies` then open `http://localhost:8080` and browse + play a mix of MP4 and MKV files including ones with EAC-3 audio and `.srt` sidecars.
- `docker compose up` on the NAS, point a browser at it, same experience.
- `make install` on the tvOS app, same experience on the TV.
- Adding/removing/renaming a file in the library is reflected in browse within a few seconds without restarting.
- Total Rust source under ~3000 lines. Web client under ~500 lines of JS. tvOS shell unchanged from the movienight pattern.
