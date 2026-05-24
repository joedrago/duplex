# Agent guidelines

## Formatting & linting

After any change in this repo, before considering the task done:

- **Rust:** must pass `cargo fmt` and `cargo clippy`.
- **JavaScript:** must pass `npm run format` (Prettier) and `npm run lint` (ESLint).

Always invoke the project-wide commands — `cargo fmt`, `cargo clippy`, `npm run format`, `npm run lint` — and let them walk the entire repo. Never run the underlying tools (`prettier`, `eslint`, `rustfmt`, etc.) directly on individual files or subdirectories. The npm-script wrappers exist so one permission grant covers every invocation; bypassing them forces a fresh approval every time.

## Helping the user debug on tvOS

The `tvos/` app runs on a real Apple TV in the user's house. You can build,
install, and stream live logs from it in one command — use this freely when
working on tvOS code or the web client it loads. Iterating against the real
device is fast (a clean build + install + launch is ~15s).

### What you need from the user, once per session

Before your first install you need two values. Ask the user up front in **one
combined question** — don't pepper them with follow-ups:

1. **Which Apple TV?** Show them the current paired devices (run `make list`
   from `tvos/` first so you give them the live list, not a stale one) and ask
   which to install onto. Save the UUID — that's `DEVICE_ID`. As of this
   writing the user typically has:
    - **Arcade (2)** — `A7A331B7-5441-520D-9FD2-711A76F08D0B`
    - **Bonus Room (2)** — `0B3FCA71-B66B-58C5-9A07-C7DC60E41411`
    - **Living Room (4)** — `0835BAAD-2EC0-54F2-A1BC-BD32BFF26E14`

    Always re-run `make list` and present what's actually there — devices come
    and go. If `make list` returns nothing, ask the user to make sure the
    target Apple TV is awake and on the same network.

2. **Where is the Duplex server reachable?** The Apple TV loads
   `WEBVIEW_URL` over the network, so `localhost` will not work — it needs
   the LAN IP/hostname of the Mac running `cargo run`. Ask for the URL in
   the form `http://<host>:2345` (the user can tell you their Mac's LAN IP,
   or you can grab it with `ipconfig getifaddr en0`).

You should also have the `DEVELOPMENT_TEAM` ID. It auto-detects from the
local signing cert (the Makefile reads `OU=...` from
`security find-certificate -c "Apple Development"`), so you usually do not
need to pass it. If a build fails with `No Account for Team ...`, the
auto-detection picked the wrong field — read `tvos/README.md` for how to
extract the right value.

### The turnkey loop

```
cd tvos
make run DEVICE_ID=<UUID> WEBVIEW_URL=http://<host>:2345
```

`make run` does build → install → launch → **stream stdout/stderr from the
running app** back to your terminal until interrupted. After any code change
in `tvos/Sources/`, `web/`, or anywhere the page being loaded lives, just
re-run this — it handles the full rebuild/reinstall cycle.

Because `make run` blocks while streaming, invoke it with `run_in_background:
true` (or your equivalent), then `Read` the output file. Wait at least ~15s
after launch for the page to load and the JS console hook to install. Stop
the process when you have what you need.

### What the logs tell you

The app is heavily instrumented. Every line is `NSLog` and shows up in the
`make run` stream. Tags to grep for:

- `[Duplex] ====...====` — launch banner with version, `WebViewURL`, OS.
- `[Duplex] lifecycle:` — foreground / background / terminate / memory
  warnings.
- `[Duplex] loadURL:` / `shouldStartLoad` / `webViewDidStartLoad` /
  `webViewDidFinishLoad` / `didFailLoadWithError` — every navigation,
  including SPA hash changes. `didFailLoadWithError` with a real
  (non-`-999`) code is the first thing to check when the page doesn't show
  up.
- `[Duplex] press DOWN: ArrowLeft` / `press UP: …` / `MENU` — Siri Remote
  presses, so you can correlate UI behavior with input.
- **`[JS:LOG] …` / `[JS:WARN] …` / `[JS:ERROR] …`** — these are
  `console.log/warn/error` calls **from inside the web client**, ferried out
  via a hidden-iframe bridge into native and re-emitted to stdio. Window
  `error` and `unhandledrejection` come through as `[JS:ERROR]
[window.error] ...` / `[unhandledrejection] ...`. This is the single most
  useful channel for debugging the page.
- `[Duplex] UNCAUGHT EXCEPTION` / `SIGNAL …` — native crashes, with a
  symbolicated-ish stack.

If the JS console output stops appearing after a full page reload, look for
a `JS console hook injected into …` line — the hook re-installs on every
`webViewDidFinishLoad`. SPA route changes (hash/pushState) do **not** re-run
the hook, but they don't need to.

### Troubleshooting

- **`No Apple TV found`** — the target device is asleep or off-network. Ask
  the user to wake it (press a remote button) or check it's on the right
  LAN.
- **`No Account for Team ...`** — wrong `DEVELOPMENT_TEAM`. See
  `tvos/README.md` § "Finding `DEVELOPMENT_TEAM`".
- **App launches but page is blank** — check `[Duplex] didFailLoadWithError`
  (network/DNS issue) and `[Duplex] WebViewURL=` in the banner (did you
  pass the right `WEBVIEW_URL`?). Then check `[JS:ERROR]` for client-side
  failures.
- **`Failed to load provisioning paramter list … No provider was found.`** —
  benign `devicectl` warning, ignore.
