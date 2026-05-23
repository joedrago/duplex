# Duplex

A small, read-only media server. Single Rust binary, vanilla-JS web client,
tvOS WebView shell.

The library on disk is the source of truth. Files are served either directly
(when natively playable) or via on-the-fly HLS that remuxes containers and,
where necessary, transcodes audio to AAC. **Video is never transcoded.**

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
| `--ffmpeg PATH`                         | ffmpeg binary.                      | `ffmpeg` on `$PATH`  |
| `--ffprobe PATH`                        | ffprobe binary.                     | `ffprobe` on `$PATH` |
| `--watch-debounce-ms N`                 | Filesystem watcher debounce window. | `300`                |
| `--dev-cors`                            | Permissive CORS (off by default).   | `false`              |

Every flag is also available as an env var prefixed `DUPLEX_` (e.g.
`DUPLEX_BIND=0.0.0.0:2345`).

There is **no config file** and the server **writes nothing to disk**. Logs go
to stderr (journald-friendly).

## What gets played how

For every file, the server inspects probe + capability matrix and picks one of:

| Decision              | Server behaviour                                                                            |
| --------------------- | ------------------------------------------------------------------------------------------- |
| `direct`              | MP4-family container, codecs in capability matrix. Served via `/api/raw` with `Range`.      |
| `hls`                 | Container needs re-muxing; video copy, audio copy. fMP4 HLS via `/api/play/...`.            |
| `hls-audio-transcode` | Audio re-encoded to AAC stereo 192k; video still copy.                                      |
| `unsupported`         | Video codec is outside the capability matrix. Surfaced in browse with a badge; no playback. |

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

## tvOS

```sh
cd tvos
make build WEBVIEW_URL=http://duplex.lan:2345
make install                    # auto-discovered Apple TV
# or
make install DEVICE_ID=…        # specific device
make list                       # list connected Apple TVs
```

Building requires Xcode plus the tvOS platform installed
(_Xcode > Settings > Components_).

## Repo layout

```
src/
  main.rs              entry, CLI, signal handling
  config.rs            CLI struct
  capability.rs        decision matrix
  library/
    mod.rs             tree model + arc-swap snapshot
    scan.rs            initial walk + sidecar binding
    watcher.rs         notify-debouncer-full driver
  probe/
    mod.rs             ffprobe JSON wrapper + cache
    keyframes.rs       keyframe time extraction + cache
  ffmpeg/mod.rs        subprocess driver (init + segments + WebVTT)
  api/
    mod.rs             axum router + AppState
    browse.rs          /api/browse
    file.rs            /api/file (probe + decision + URLs)
    raw.rs             /api/raw (range-aware passthrough)
    hls.rs             /api/play/<vpath>/{master,v/...,a/<idx>/...}
    subs.rs            /api/subs (sidecar + embedded → WebVTT)
    web.rs             embedded static client
    vpath.rs           URL path normalisation/encoding
web/                   embedded UI (rust-embed)
tvos/                  xcodegen-driven WKWebView shell
```

## Known limitations

- Image-based subtitles (PGS, VobSub, DVDSub) are inventoried but not rendered.
- ASS styling is downconverted to plain WebVTT.
- Subtitles are served as a single VTT covering the whole duration. All
  mainstream players accept this.
- No watch-progress, accounts, posters, or transcoding queue. By design.
