// Tiny vanilla-JS client. Hash-routed:
//   #/browse/<path>     (path may be empty, "Movies", "Movies/Action", ...)
//   #/play/<path>
//
// All routing is driven by `location.hash` so the server doesn't have to know
// about client routes.

const app = document.getElementById("app")
const crumbs = document.getElementById("crumbs")

function encodePath(p) {
    return p.split("/").filter(Boolean).map(encodeURIComponent).join("/")
}

function parseRoute() {
    const h = location.hash.replace(/^#/, "") || "/browse/"
    const m = h.match(/^\/(browse|play)\/(.*)$/)
    if (!m) return { kind: "browse", path: "" }
    const rawPath = m[2] || ""
    const path = rawPath.split("/").map(decodeURIComponent).filter(Boolean).join("/")
    return { kind: m[1], path }
}

function renderCrumbs(path) {
    crumbs.innerHTML = ""
    const parts = path.split("/").filter(Boolean)
    let acc = ""
    const root = document.createElement("a")
    root.href = "#/browse/"
    root.textContent = "/"
    crumbs.appendChild(root)
    parts.forEach((p, i) => {
        acc = acc ? acc + "/" + p : p
        const sep = document.createElement("span")
        sep.className = "sep"
        sep.textContent = "/"
        crumbs.appendChild(sep)
        if (i + 1 < parts.length) {
            const a = document.createElement("a")
            a.href = "#/browse/" + encodePath(acc)
            a.textContent = p
            crumbs.appendChild(a)
        } else {
            const span = document.createElement("span")
            span.textContent = p
            crumbs.appendChild(span)
        }
    })
}

async function getJSON(url) {
    const r = await fetch(url)
    if (!r.ok) throw new Error(`${r.status} ${r.statusText}`)
    return r.json()
}

function el(tag, props, ...children) {
    const e = document.createElement(tag)
    Object.assign(e, props || {})
    for (const c of children.flat()) {
        if (c == null) continue
        e.append(c.nodeType ? c : document.createTextNode(c))
    }
    return e
}

async function renderBrowse(path) {
    renderCrumbs(path)
    app.replaceChildren(el("p", { className: "muted" }, "loading…"))
    let data
    try {
        data = await getJSON("/api/browse?path=" + encodeURIComponent(path))
    } catch (e) {
        app.replaceChildren(el("div", { className: "error" }, "browse failed: " + e.message))
        return
    }
    const grid = el("div", { className: "grid" })
    if (data.entries.length === 0) {
        grid.append(el("p", null, "(empty directory)"))
    }
    for (const entry of data.entries) {
        const full = path ? path + "/" + entry.name : entry.name
        if (entry.kind === "dir") {
            const tile = el(
                "a",
                { className: "tile dir", href: "#/browse/" + encodePath(full) },
                el("div", { className: "name" }, entry.name),
                el("div", { className: "meta" }, `${entry.children} entries`)
            )
            grid.append(tile)
        } else {
            const meta = [`${prettySize(entry.size)}`]
            if (entry.ext) meta.push(entry.ext)
            const badge = entry.decision ? el("span", { className: "badge " + entry.decision }, entry.decision) : null
            const tile = el(
                "a",
                { className: "tile file", href: "#/play/" + encodePath(full) },
                el("div", { className: "name" }, entry.name, badge),
                el("div", { className: "meta" }, meta.join(" · "))
            )
            grid.append(tile)
        }
    }
    app.replaceChildren(grid)
}

function prettySize(n) {
    if (!n) return "?"
    const u = ["B", "KB", "MB", "GB", "TB"]
    let i = 0
    while (n >= 1024 && i < u.length - 1) {
        n /= 1024
        i++
    }
    return `${n.toFixed(n < 10 ? 2 : 1)} ${u[i]}`
}

let activeHls = null
let activeRecovery = null

function teardownPlayer() {
    if (activeRecovery) {
        activeRecovery.stop()
        activeRecovery = null
    }
    if (activeHls) {
        activeHls.destroy()
        activeHls = null
    }
}

// Keeps the HLS pipeline alive in the face of transient muxer errors,
// audio-track switches that never finish buffering, and other "the
// player gave up" cases. Standard hls.js recovery (recoverMediaError /
// startLoad) handles the easy cases; for everything else we fall back
// to a full source reload at the last known position. A stall watchdog
// catches the case where the player thinks it's playing but the media
// element hasn't advanced.
function installHlsRecovery({ hls, video, getMasterUrl }) {
    let lastTime = 0
    let lastAdvanceAt = performance.now()
    let recoveryAttempts = 0
    let reloadPending = false
    let stopped = false

    const onTimeUpdate = () => {
        if (!Number.isNaN(video.currentTime) && video.currentTime > 0) {
            if (video.currentTime !== lastTime) {
                lastAdvanceAt = performance.now()
            }
            lastTime = video.currentTime
        }
    }
    video.addEventListener("timeupdate", onTimeUpdate)

    const onFragLoaded = () => {
        recoveryAttempts = 0
    }
    hls.on(window.Hls.Events.FRAG_LOADED, onFragLoaded)

    const fullReload = () => {
        if (stopped || reloadPending) return
        reloadPending = true
        const wasPlaying = !video.paused
        const resumeAt = lastTime
        console.warn(`[hls] full reload at ${resumeAt.toFixed(2)}s`)
        try {
            hls.loadSource(getMasterUrl())
        } catch (e) {
            console.warn("[hls] loadSource threw", e)
        }
        const onCanPlay = () => {
            video.removeEventListener("canplay", onCanPlay)
            if (resumeAt > 0) video.currentTime = resumeAt
            if (wasPlaying) video.play().catch(() => {})
            reloadPending = false
            lastAdvanceAt = performance.now()
        }
        video.addEventListener("canplay", onCanPlay)
        // If `canplay` never fires (e.g. the new manifest also fails),
        // clear the latch after a generous timeout so the watchdog can
        // attempt another reload.
        setTimeout(() => {
            if (reloadPending) {
                video.removeEventListener("canplay", onCanPlay)
                reloadPending = false
            }
        }, 30000)
    }

    const onError = (_evt, data) => {
        if (!data.fatal) return
        console.warn("[hls] fatal error", data.type, data.details)
        if (recoveryAttempts < 2) {
            recoveryAttempts++
            try {
                if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) {
                    hls.recoverMediaError()
                    return
                }
                if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) {
                    hls.startLoad()
                    return
                }
            } catch (e) {
                console.warn("[hls] recovery threw", e)
            }
        }
        fullReload()
    }
    hls.on(window.Hls.Events.ERROR, onError)

    // Stall watchdog: if we expect to be playing but currentTime hasn't
    // moved for STALL_LIMIT_MS, force a full reload. Catches the case
    // where hls.js has silently given up and isn't emitting errors.
    const STALL_LIMIT_MS = 15000
    const watchdog = setInterval(() => {
        if (stopped || video.paused || reloadPending) return
        const sinceAdvance = performance.now() - lastAdvanceAt
        if (sinceAdvance > STALL_LIMIT_MS && video.readyState < 3) {
            console.warn(`[hls] stalled ${(sinceAdvance / 1000).toFixed(1)}s, reloading`)
            fullReload()
        }
    }, 2000)

    return {
        notePosition(t) {
            if (typeof t === "number" && !Number.isNaN(t)) {
                lastTime = t
                lastAdvanceAt = performance.now()
            }
        },
        stop() {
            stopped = true
            clearInterval(watchdog)
            video.removeEventListener("timeupdate", onTimeUpdate)
            try {
                hls.off(window.Hls.Events.ERROR, onError)
                hls.off(window.Hls.Events.FRAG_LOADED, onFragLoaded)
            } catch (_) {}
        },
    }
}

async function renderPlay(path) {
    teardownPlayer()
    renderCrumbs(path)
    app.replaceChildren(el("p", null, "loading…"))
    let info
    try {
        info = await getJSON("/api/file?path=" + encodeURIComponent(path))
    } catch (e) {
        app.replaceChildren(el("div", { className: "error" }, "load failed: " + e.message))
        return
    }

    if (info.decision === "unsupported") {
        const vc = info.probe?.streams?.find((s) => s.codec_type === "video")?.codec_name || "?"
        app.replaceChildren(
            el("div", { className: "error" }, `unsupported: video codec ${vc} is not in this device's capability matrix.`),
            detailsBlock(info)
        )
        return
    }

    const video = el("video", { playsInline: true, autoplay: true })
    const cueOverlay = el("div", { className: "cue-overlay" })

    const subOpts = [el("option", { value: "" }, "subtitles: off")]
    info.sidecars?.forEach((s, i) => {
        subOpts.push(el("option", { value: "sidecar:" + i }, `${s.language || "?"} (sidecar ${s.format})`))
    })
    info.embedded_subs?.forEach((s) => {
        if (s.format === "text") {
            subOpts.push(el("option", { value: "embedded:" + s.index }, `${s.language || "?"} (embedded ${s.codec || "text"})`))
        }
    })
    const subSelect = el("select", { className: "ctrl-subs", title: "subtitles" }, ...subOpts)

    // Audio track dropdown — only when HLS is in play and there's more than
    // one track. Direct-play uses the raw file and the browser picks audio;
    // we can't switch tracks server-side in that mode.
    const audioTracks = info.audio_tracks ?? []
    const audioSelect =
        info.decision !== "direct" && audioTracks.length > 1
            ? el(
                  "select",
                  { className: "ctrl-audio", title: "audio track" },
                  ...audioTracks.map((a, i) => {
                      const lang = a.language || `audio ${i + 1}`
                      const chInfo = a.channel_layout || (a.channels ? `${a.channels}ch` : null)
                      const ch = chInfo ? ` (${chInfo})` : ""
                      return el("option", { value: a.index }, `${lang}${ch}`)
                  })
              )
            : null

    const playBtn = el("button", { className: "ctrl-btn ctrl-play", title: "play/pause" }, "▶")
    const scrub = el("input", { type: "range", className: "ctrl-scrub", min: "0", max: "100", step: "any", value: "0" })
    const timeDisplay = el("span", { className: "ctrl-time" }, "0:00 / 0:00")
    const muteBtn = el("button", { className: "ctrl-btn ctrl-mute", title: "mute" }, "♪")
    const volumeSlider = el("input", { type: "range", className: "ctrl-volume", min: "0", max: "1", step: "0.01", value: "1" })
    const fsBtn = el("button", { className: "ctrl-btn ctrl-fs", title: "fullscreen" }, "⛶")

    const controlBar = el(
        "div",
        { className: "player-controls" },
        playBtn,
        scrub,
        timeDisplay,
        muteBtn,
        volumeSlider,
        audioSelect,
        subSelect,
        fsBtn
    )

    const stage = el("div", { className: "player-stage" }, video, cueOverlay, controlBar)
    const wrap = el("div", { className: "player" }, stage, detailsBlock(info))
    app.replaceChildren(wrap)

    const masterUrlFor = (audioIdx) => `${info.urls.master}${audioIdx !== undefined ? `?audio=${audioIdx}` : ""}`
    const initialAudio = audioTracks[0]?.index
    let currentAudio = initialAudio

    if (info.decision === "direct") {
        video.src = info.urls.raw
    } else if (window.Hls && window.Hls.isSupported()) {
        const hls = new window.Hls({ debug: false })
        activeHls = hls
        hls.loadSource(masterUrlFor(initialAudio))
        hls.attachMedia(video)
        activeRecovery = installHlsRecovery({
            hls,
            video,
            getMasterUrl: () => masterUrlFor(currentAudio),
        })
    } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = masterUrlFor(initialAudio)
    } else {
        app.replaceChildren(el("div", { className: "error" }, "no HLS support in this browser"))
        return
    }

    if (audioSelect && activeHls) {
        audioSelect.addEventListener("change", () => {
            const audioIdx = parseInt(audioSelect.value, 10)
            const curTime = video.currentTime
            const wasPlaying = !video.paused
            currentAudio = audioIdx
            if (activeRecovery) activeRecovery.notePosition(curTime)
            activeHls.loadSource(masterUrlFor(audioIdx))
            video.addEventListener("canplay", function onCanPlay() {
                video.removeEventListener("canplay", onCanPlay)
                video.currentTime = curTime
                if (wasPlaying) video.play()
            })
        })
    }

    attachPlayerControls({ video, stage, playBtn, scrub, timeDisplay, muteBtn, volumeSlider, fsBtn })

    subSelect.addEventListener("change", () => {
        ;[...video.querySelectorAll("track")].forEach((t) => t.remove())
        cueOverlay.textContent = ""
        const val = subSelect.value
        if (!val) return
        const t = document.createElement("track")
        t.kind = "subtitles"
        t.default = true
        t.label = subSelect.selectedOptions[0].textContent
        t.src = `/api/subs?path=${encodeURIComponent(path)}&track=${encodeURIComponent(val)}`
        t.srclang = "en"
        video.append(t)
        // Switch the track to `hidden` so the browser stops painting cues on
        // the video itself; we render them into the cueOverlay anchored to
        // the stage instead. The cuechange event still fires in hidden mode.
        setTimeout(() => {
            ;[...video.textTracks].forEach((tt) => {
                tt.mode = "hidden"
                tt.oncuechange = () => {
                    const active = [...(tt.activeCues || [])]
                    cueOverlay.textContent = active.map((c) => c.text).join("\n")
                }
            })
        }, 50)
    })
}

// Wires every custom control to the <video> element and handles
// auto-hide. Bidirectional: input events drive the video, video events
// (timeupdate, volumechange, play, pause, …) keep the controls in sync,
// so the controls stay correct even when the user pauses via spacebar,
// the browser autoplays, or fullscreen is exited via Esc.
function attachPlayerControls({ video, stage, playBtn, scrub, timeDisplay, muteBtn, volumeSlider, fsBtn }) {
    let scrubbing = false

    const updatePlay = () => {
        playBtn.textContent = video.paused ? "▶" : "⏸"
    }
    const updateMute = () => {
        muteBtn.classList.toggle("muted", video.muted || video.volume === 0)
    }
    const updateFs = () => {
        fsBtn.textContent = document.fullscreenElement ? "⛶" : "⛶"
    }

    playBtn.addEventListener("click", () => {
        video.paused ? video.play() : video.pause()
    })
    video.addEventListener("play", updatePlay)
    video.addEventListener("pause", updatePlay)
    video.addEventListener("ended", updatePlay)

    video.addEventListener("loadedmetadata", () => {
        if (isFinite(video.duration)) scrub.max = String(video.duration)
    })
    video.addEventListener("durationchange", () => {
        if (isFinite(video.duration)) scrub.max = String(video.duration)
    })
    video.addEventListener("timeupdate", () => {
        if (!scrubbing) scrub.value = String(video.currentTime)
        timeDisplay.textContent = `${fmtTime(video.currentTime)} / ${fmtTime(video.duration)}`
    })
    scrub.addEventListener("input", () => {
        scrubbing = true
        timeDisplay.textContent = `${fmtTime(parseFloat(scrub.value))} / ${fmtTime(video.duration)}`
    })
    scrub.addEventListener("change", () => {
        video.currentTime = parseFloat(scrub.value)
        scrubbing = false
    })

    muteBtn.addEventListener("click", () => {
        video.muted = !video.muted
    })
    volumeSlider.addEventListener("input", () => {
        video.volume = parseFloat(volumeSlider.value)
        video.muted = video.volume === 0
    })
    video.addEventListener("volumechange", () => {
        updateMute()
        volumeSlider.value = String(video.muted ? 0 : video.volume)
    })

    fsBtn.addEventListener("click", () => {
        if (document.fullscreenElement) document.exitFullscreen()
        else stage.requestFullscreen().catch(() => {})
    })
    document.addEventListener("fullscreenchange", updateFs)

    video.addEventListener("click", () => {
        video.paused ? video.play() : video.pause()
    })

    // Spacebar toggles play/pause while the player is in view and a form
    // control isn't focused.
    const onKey = (ev) => {
        if (ev.code !== "Space") return
        const tag = (document.activeElement?.tagName || "").toLowerCase()
        if (tag === "input" || tag === "select" || tag === "textarea") return
        ev.preventDefault()
        video.paused ? video.play() : video.pause()
    }
    document.addEventListener("keydown", onKey)

    let hideTimer = null
    const showControls = () => {
        stage.classList.add("show-controls")
        if (hideTimer) {
            clearTimeout(hideTimer)
            hideTimer = null
        }
        if (!video.paused) {
            hideTimer = setTimeout(() => stage.classList.remove("show-controls"), 2500)
        }
    }
    stage.addEventListener("mousemove", showControls)
    stage.addEventListener("mouseenter", showControls)
    stage.addEventListener("mouseleave", () => {
        if (!video.paused) stage.classList.remove("show-controls")
    })
    video.addEventListener("pause", showControls)
    showControls()

    updatePlay()
    updateMute()

    // Keep `--stage-h` in sync with the stage's actual rendered height so
    // .cue-overlay can size subtitles as a percentage of the player
    // container (not the viewport, not the video).
    const setStageH = () => {
        stage.style.setProperty("--stage-h", stage.clientHeight + "px")
    }
    setStageH()
    new ResizeObserver(setStageH).observe(stage)
}

function fmtTime(s) {
    if (!isFinite(s) || s < 0) return "0:00"
    s = Math.floor(s)
    const h = Math.floor(s / 3600)
    const m = Math.floor((s % 3600) / 60)
    const ss = s % 60
    const pad = (n) => String(n).padStart(2, "0")
    return h > 0 ? `${h}:${pad(m)}:${pad(ss)}` : `${m}:${pad(ss)}`
}

function detailsBlock(info) {
    if (!new URLSearchParams(window.location.search).has("debug")) {
        return document.createDocumentFragment()
    }
    return el(
        "details",
        null,
        el("summary", null, `${info.decision} — ${info.path}`),
        el("pre", null, JSON.stringify(info.probe, null, 2))
    )
}

function render() {
    const r = parseRoute()
    if (r.kind === "play") renderPlay(r.path)
    else renderBrowse(r.path)
}

window.addEventListener("hashchange", render)
window.addEventListener("DOMContentLoaded", () => {
    if (!location.hash) location.hash = "#/browse/"
    render()
})
