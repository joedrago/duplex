# Duplex

A small, read-only media server. Single Rust binary, vanilla-JS web client.

The library on disk is the source of truth. The server is "metadata + range
requests": it scans the library, probes files with ffprobe, and serves their
raw bytes over HTTP Range. **The browser does everything else** — demuxing,
decoding, audio downmix, and subtitle rendering — via Mediabunny + the
WebCodecs API. No HLS, no server-side transcoding, no ffmpeg subprocess at
playback time.

> tvOS used to be a target via a WKWebView shell loading the same web client;
> that shell is currently out of scope and may not work. A native tvOS client
> is the long-term plan.

See `PLAN.md` for the long-form design.

## Quick start

```sh
cargo run -- --library ~/Movies --library ~/TV
```

Then open <http://localhost:2345> in Safari or Chrome. Each `--library` becomes
a top-level virtual directory named by the path's basename. Two roots that
collide on basename will refuse to start — rename one on disk.

## Flags

| Flag                                    | Description                         | Default              |
| --------------------------------------- | ----------------------------------- | -------------------- |
| `--library PATH` (repeatable, required) | Library root to serve.              | —                    |
| `--bind ADDR`                           | HTTP bind address.                  | `127.0.0.1:2345`     |
| `--log LEVEL`                           | `RUST_LOG`-style filter.            | `info`               |
| `--ffprobe PATH`                        | ffprobe binary (only used at scan). | `ffprobe` on `$PATH` |
| `--watch-debounce-ms N`                 | Filesystem watcher debounce window. | `300`                |
| `--dev-cors`                            | Permissive CORS (off by default).   | `false`              |
| `--js-logs`                             | Mirror browser console to stderr.   | `false`              |

Every flag is also available as an env var prefixed `DUPLEX_` (e.g.
`DUPLEX_BIND=0.0.0.0:2345`).

There is **no config file** and the server **writes nothing to disk**. Logs go
to stderr (journald-friendly).

## What gets played how

Everything is client-side. The server hands the browser raw bytes (with HTTP
Range support) and a small JSON manifest listing tracks + codec strings.
Mediabunny demuxes the container; the browser's WebCodecs API decodes the
streams; the player paints to `<canvas>` and schedules audio through the
AudioContext clock.

Three things can go wrong, and the player surfaces each clearly:

- **Video codec not decodable by this browser** (e.g. HEVC on Firefox, AV1
  on older Intel Macs). Inline error: "this browser can't decode \<codec>".
- **Audio codec not decodable** (e.g. AC-3 in Chrome builds without the
  proprietary Dolby decoders). Audio mutes; the audio button shows 🔇 and
  the picker labels the offending tracks `— unsupported`.
- **AudioContext suspended** (autoplay policy on hard refresh or deep link).
  A big tap-to-play overlay appears; first click resumes everything.

## Repo layout

```
src/
  main.rs              entry, CLI, signal handling
  config.rs            CLI struct
  library/             scan + watcher + tree
  probe/mod.rs         ffprobe JSON wrapper + cache
  api/
    mod.rs             axum router, AppState, COOP/COEP/CORP headers
    browse.rs          /api/browse
    manifest.rs        /api/manifest (slim track + sidecar list)
    raw.rs             /api/raw (range-aware passthrough)
    sidecar.rs         /api/sidecar (raw subtitle bytes)
    recent.rs          /api/recent
    next.rs            /api/next
    debug.rs           /_debug/log (mirror browser console)
    web.rs             embedded static client
    vpath.rs           URL path normalisation/encoding
    codec_string.rs    avc1/hvc1/etc. codec strings for the manifest
web/                   vanilla-JS client (rust-embed'd)
  app.js               UI / browse / poster grid / picker / controls
  player.js            WebCodecs + Mediabunny player (+ playback speed)
  mkv-subs.js          streaming Matroska subtitle-track reader (Range-based)
  pgs.js               PGS (image subtitle) decoder + canvas overlay
  embedded-subs.js     playhead-following PGS/ASS renderer (uses the above)
  vendor/mediabunny.mjs    (vendored, jsdelivr +esm bundle)
  vendor/jassub/           (vendored JASSUB — libass-in-WASM, for ASS)
```

## systemd

Run as a service on a Linux box with a read-only NAS mount:

```ini
# /etc/systemd/system/duplex.service
[Unit]
Description=Duplex media server
After=network-online.target remote-fs.target
Wants=network-online.target

[Service]
Type=simple
User=duplex
ExecStart=/usr/local/bin/duplex --library /mnt/media/Movies --library /mnt/media/TV --bind 0.0.0.0:2345
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

`systemctl daemon-reload && systemctl enable --now duplex` and you're done.

## Known limitations

- **AC-3 / E-AC-3 audio** isn't decodable in Chrome builds that lack the
  proprietary Dolby decoders. The audio button shows 🔇 and the picker
  labels offending tracks `— unsupported`. Future: in-browser WASM decode.
- **HEVC** on Firefox, **AV1** on older Intel Macs: clean inline error.
- **Embedded subtitles in MKV** (PGS image subs + ASS/SRT text) now render in
  the web client via a purpose-built Matroska subtitle reader
  (`web/mkv-subs.js`) — Mediabunny still won't surface them. PGS is decoded to
  bitmaps (`web/pgs.js`); ASS renders with full styling through JASSUB plus the
  file's embedded fonts (`web/embedded-subs.js`). Subtitle tracks **inside MP4**
  (mov_text) and **VobSub / DVDSub** are not yet handled. Sidecar subtitles
  work as before.
- No watch-progress sync across devices, no accounts. By design.
