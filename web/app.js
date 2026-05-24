// Tiny vanilla-JS client. Hash-routed:
//   #/browse/<path>     (path may be empty, "Movies", "Movies/Action", ...)
//   #/play/<path>
//   #/settings
//
// All routing is driven by `location.hash` so the server doesn't have to know
// about client routes.

const app = document.getElementById("app")
const crumbs = document.getElementById("crumbs")
const headerActions = document.getElementById("header-actions")

// Sort mode for the browse grid. Persisted in localStorage so the user gets
// the same order on next launch. Continue Watching and the root Recently
// Added section have their own intrinsic order; this only governs the main
// directory listing.
const SORT_KEY = "duplex.sort"
function getSort() {
    try {
        return localStorage.getItem(SORT_KEY) || "name"
    } catch {
        return "name"
    }
}
function setSort(v) {
    try {
        localStorage.setItem(SORT_KEY, v)
    } catch (e) {
        console.warn("[sort] write failed", e)
    }
}

// Resume-position store. Map of vpath -> {pos, dur, at}. Lives in
// localStorage so it survives across sessions but never touches the server's
// disk (the server is read-only by design). Pruned at write time: entries in
// the first 5s or beyond 95% of duration are removed so "Continue Watching"
// doesn't list things you barely started or already finished.
const RESUME_KEY = "duplex.resume"
const RESUME_HEAD_S = 5
const RESUME_TAIL_FRAC = 0.95

function readResumeMap() {
    try {
        return JSON.parse(localStorage.getItem(RESUME_KEY) || "{}") || {}
    } catch {
        return {}
    }
}
function writeResumeMap(m) {
    try {
        localStorage.setItem(RESUME_KEY, JSON.stringify(m))
    } catch (e) {
        console.warn("[resume] write failed", e)
    }
}
function setResume(path, pos, dur) {
    if (!path || !isFinite(pos) || !isFinite(dur) || dur <= 0) return
    const m = readResumeMap()
    if (pos < RESUME_HEAD_S || pos > dur * RESUME_TAIL_FRAC) {
        if (path in m) {
            delete m[path]
            writeResumeMap(m)
            console.log(`[resume] cleared "${path}" (pos=${pos.toFixed(1)}s of ${dur.toFixed(0)}s)`)
        }
        return
    }
    m[path] = { pos, dur, at: Date.now() }
    writeResumeMap(m)
}
function clearResume(path) {
    const m = readResumeMap()
    if (path in m) {
        delete m[path]
        writeResumeMap(m)
        console.log(`[resume] cleared "${path}"`)
    }
}
function getResume(path) {
    return readResumeMap()[path] || null
}

// Diagnostic: probe localStorage durability across app relaunches.
// Logs what we read on this launch, then stamps a fresh value so the next
// launch can verify persistence. Safe to leave in; cheap and informative.
;(function probeLocalStorage() {
    try {
        const key = "duplex.storageProbe"
        const prev = localStorage.getItem(key)
        const keys = localStorage.length
        const now = new Date().toISOString()
        if (prev) {
            const elapsedMin = ((Date.now() - new Date(prev).getTime()) / 60000).toFixed(1)
            console.log(`[storage] localStorage OK — ${keys} keys, last write ${prev} (${elapsedMin} min ago)`)
        } else {
            console.log(`[storage] localStorage empty (${keys} keys) — first probe write at ${now}`)
        }
        localStorage.setItem(key, now)
        console.log(`[storage] wrote ${key}=${now}, now ${localStorage.length} keys`)
    } catch (e) {
        console.error(`[storage] localStorage threw: ${e.message || e}`)
    }
})()

function encodePath(p) {
    return p.split("/").filter(Boolean).map(encodeURIComponent).join("/")
}

function parseRoute() {
    const h = location.hash.replace(/^#/, "") || "/browse/"
    if (h === "/settings" || h === "/settings/") return { kind: "settings", path: "" }
    const m = h.match(/^\/(browse|play)\/(.*)$/)
    if (!m) return { kind: "browse", path: "" }
    const rawPath = m[2] || ""
    const path = rawPath.split("/").map(decodeURIComponent).filter(Boolean).join("/")
    return { kind: m[1], path }
}

function renderCrumbs(path, clickable) {
    crumbs.innerHTML = ""
    const parts = path.split("/").filter(Boolean)
    let acc = ""
    parts.forEach((p, i) => {
        acc = acc ? acc + "/" + p : p
        const sep = document.createElement("span")
        sep.className = "sep"
        sep.textContent = " / "
        crumbs.appendChild(sep)
        const isClickable = clickable !== false && !(clickable === "dirs" && i === parts.length - 1)
        if (isClickable) {
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

function renderSortToggle() {
    const cur = getSort()
    const make = (val, label) => {
        const btn = el("button", { className: "sort-pill" + (cur === val ? " active" : ""), type: "button" }, label)
        btn.addEventListener("click", () => {
            if (getSort() === val) return
            setSort(val)
            render()
        })
        return btn
    }
    return el(
        "div",
        { className: "sort-toggle", title: "Sort order" },
        el("span", { className: "sort-label" }, "Sort"),
        make("name", "Name"),
        make("recent", "Recent")
    )
}

function clearHeaderActions() {
    headerActions.replaceChildren()
}

function sortEntries(entries, mode) {
    if (mode !== "recent") return entries
    // Stable secondary by name so equal mtimes (or zero mtimes from unknown
    // values) still produce a predictable order.
    return [...entries].sort((a, b) => {
        const dm = (b.mtime || 0) - (a.mtime || 0)
        if (dm !== 0) return dm
        return a.name.localeCompare(b.name)
    })
}

async function renderBrowse(path) {
    document.documentElement.classList.remove("player-active")
    renderCrumbs(path)
    clearHeaderActions()
    headerActions.append(renderSortToggle())
    app.replaceChildren(el("p", { className: "muted" }, "loading…"))
    let data
    try {
        data = await getJSON("/api/browse?path=" + encodeURIComponent(path))
    } catch (e) {
        app.replaceChildren(el("div", { className: "error" }, "browse failed: " + e.message))
        return
    }
    if (path === "") {
        renderRoot(data)
    } else {
        renderSubdir(path, data)
    }
}

// Root view: three independently-scrollable columns side by side.
// Continue Watching (from localStorage) | Recently Added (server-fetched) |
// Libraries (the data.entries from /api/browse?path=).
function renderRoot(data) {
    const columns = el("div", { className: "columns columns-root" })

    // Order: Libraries | Recently Added | Continue Watching.
    // The Continue column's per-row ✕ button is the rightmost selectable on
    // its row; putting Continue on the far right means Right past it lands
    // nowhere instead of accidentally on a destructive button while the
    // user is trying to cross from Recently Added.
    columns.append(renderLibrariesColumn(data))

    const recentList = el("ul", { className: "col-list" }, el("li", { className: "col-empty" }, "loading…"))
    const recentCol = el("section", { className: "col col-recent" }, columnHeader("Recently Added"), recentList)
    columns.append(recentCol)
    fetchAndPopulateRecent(recentCol)

    const continueCol = renderContinueColumn()
    if (continueCol) columns.append(continueCol)

    app.replaceChildren(columns)
}

// Subdir view: one full-width column with the directory listing + alphabet
// rail on the right when the list is long enough to be worth navigating.
function renderSubdir(path, data) {
    const sorted = sortEntries(data.entries, getSort())
    // Folders-first when sorting by name (conventional file-manager order).
    // With Recent sort, dirs + files interleave by mtime so freshly-added
    // content surfaces regardless of kind.
    const ordered = getSort() === "recent" ? sorted : [...sorted].sort(folderFirst)

    const list = el("ul", { className: "col-list" })
    if (ordered.length === 0) list.append(el("li", { className: "col-empty" }, "(empty directory)"))
    for (const entry of ordered) {
        const full = path ? path + "/" + entry.name : entry.name
        list.append(makeBrowseRow(entry, full))
    }

    const body = el("div", { className: "col-body" }, list)
    const ALPHABET_RAIL_THRESHOLD = 20
    if (ordered.length >= ALPHABET_RAIL_THRESHOLD) {
        body.append(buildAlphabetRail(ordered, list))
    }

    const col = el("section", { className: "col col-subdir" }, columnHeader(basenameOf(path) || "Library"), body)
    app.replaceChildren(el("div", { className: "columns columns-subdir" }, col))

    list.addEventListener("click", (ev) => {
        const row = ev.target.closest(".col-row")
        if (!row) return
        try {
            localStorage.setItem("duplex.last:" + path, row.dataset.name)
        } catch (e) {
            void e
        }
    })
    try {
        const lastName = localStorage.getItem("duplex.last:" + path)
        if (lastName) {
            for (const r of list.querySelectorAll(".col-row")) {
                if (r.dataset.name === lastName) {
                    setSelection(r.querySelector(".row-link") || r)
                    break
                }
            }
        }
    } catch (e) {
        void e
    }
}

function folderFirst(a, b) {
    if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1
    return a.name.localeCompare(b.name)
}

function basenameOf(path) {
    if (!path) return ""
    const parts = path.split("/").filter(Boolean)
    return parts[parts.length - 1] || ""
}

function columnHeader(title) {
    return el("h2", { className: "col-header" }, title)
}

// One browse-listing row used in subdir view and the Libraries column.
function makeBrowseRow(entry, vpath) {
    const isDir = entry.kind === "dir"
    const href = isDir ? "#/browse/" + encodePath(vpath) : "#/play/" + encodePath(vpath)
    const icon = el("span", { className: "row-icon" }, isDir ? "📁" : "🎬")
    const name = el("div", { className: "row-name" }, entry.name)
    if (!isDir && entry.decision) name.append(el("span", { className: "badge " + entry.decision }, entry.decision))
    const metaParts = isDir
        ? [`${entry.children} ${entry.children === 1 ? "entry" : "entries"}`]
        : [prettySize(entry.size), entry.ext].filter(Boolean)
    const meta = el("div", { className: "row-meta" }, metaParts.join(" · "))
    const link = el(
        "a",
        { className: "row-link" + (isDir ? " row-dir" : " row-file"), href },
        icon,
        el("div", { className: "row-text" }, name, meta)
    )
    const row = el("li", { className: "col-row" }, link)
    row.dataset.name = entry.name
    return row
}

// "Continue Watching" column: vertical list of rows, each with a small
// inline "✕" remove button. Returns null when the resume map is empty so
// the root view can omit the column entirely.
function renderContinueColumn() {
    const items = continueItems()
    if (items.length === 0) return null

    const list = el("ul", { className: "col-list" })
    const section = el("section", { className: "col col-continue" }, columnHeader("Continue Watching"), list)

    const rebuild = () => {
        const fresh = renderContinueColumn()
        if (fresh) {
            section.replaceWith(fresh)
            const first = fresh.querySelector(".row-link")
            if (first) setSelection(first)
        } else {
            section.remove()
            const next = document.querySelector(".col-recent .row-link, .col-libraries .row-link")
            if (next) setSelection(next)
        }
    }

    for (const it of items) {
        const basename = it.vpath.split("/").pop() || it.vpath
        const remaining = Math.max(0, it.dur - it.pos)
        const pct = Math.max(0, Math.min(100, (it.pos / it.dur) * 100))
        const link = el(
            "a",
            { className: "row-link row-file", href: "#/play/" + encodePath(it.vpath) },
            el("span", { className: "row-icon" }, "🎬"),
            el(
                "div",
                { className: "row-text" },
                el("div", { className: "row-name" }, basename),
                el("div", { className: "row-meta" }, `${fmtTime(remaining)} left`)
            ),
            el(
                "div",
                { className: "row-progress" },
                el("div", { className: "row-progress-fill", style: `width:${pct.toFixed(1)}%` })
            )
        )
        const removeBtn = el(
            "button",
            { className: "row-action", type: "button", title: "Forget this position", "aria-label": "Forget" },
            "✕"
        )
        removeBtn.addEventListener("click", (ev) => {
            ev.preventDefault()
            ev.stopPropagation()
            clearResume(it.vpath)
            rebuild()
        })
        const row = el("li", { className: "col-row col-row-continue" }, link, removeBtn)
        row.dataset.name = basename
        list.append(row)
    }
    return section
}

function continueItems() {
    const m = readResumeMap()
    return Object.entries(m)
        .map(([vpath, info]) => ({ vpath, ...info }))
        .filter((it) => isFinite(it.pos) && isFinite(it.dur) && it.dur > 0)
        .sort((a, b) => (b.at || 0) - (a.at || 0))
}

async function fetchAndPopulateRecent(col) {
    let data
    try {
        data = await getJSON("/api/recent?limit=30")
    } catch (e) {
        console.warn("[recent] fetch failed", e)
        col.remove()
        return
    }
    const list = col.querySelector(".col-list")
    if (!data.items || data.items.length === 0) {
        list.replaceChildren(el("li", { className: "col-empty" }, "Nothing new"))
        return
    }
    list.replaceChildren()
    for (const it of data.items) {
        const parts = it.vpath.split("/")
        const basename = parts.pop()
        const parent = parts.join(" / ")
        const link = el(
            "a",
            { className: "row-link row-file", href: "#/play/" + encodePath(it.vpath) },
            el("span", { className: "row-icon" }, "🎬"),
            el(
                "div",
                { className: "row-text" },
                parent ? el("div", { className: "row-context" }, parent) : null,
                el("div", { className: "row-name" }, basename),
                el("div", { className: "row-meta" }, `${prettySize(it.size)} · ${formatRelative(it.mtime)}`)
            )
        )
        const row = el("li", { className: "col-row" }, link)
        row.dataset.name = basename
        list.append(row)
    }
}

function renderLibrariesColumn(data) {
    const sorted = sortEntries(data.entries, getSort())
    const list = el("ul", { className: "col-list" })
    if (sorted.length === 0) list.append(el("li", { className: "col-empty" }, "No libraries"))
    for (const entry of sorted) {
        list.append(makeBrowseRow(entry, entry.name))
    }
    return el("section", { className: "col col-libraries" }, columnHeader("Libraries"), list)
}

// Bucket an entry name's first character into "#"+A..Z so the rail can map
// a letter to matching rows quickly. Non-ASCII letters fall into "#".
function firstLetterBucket(name) {
    const c = (name || "").trimStart().charAt(0).toUpperCase()
    if (c >= "A" && c <= "Z") return c
    return "#"
}

function buildAlphabetRail(entries, list) {
    const LETTERS = ["#", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"]
    const presentSet = new Set(entries.map((e) => firstLetterBucket(e.name)))
    const rail = el("aside", { className: "alphabet-rail", role: "navigation" })

    const jumpTo = (letter) => {
        const rows = list.querySelectorAll(".col-row")
        for (const r of rows) {
            if (firstLetterBucket(r.dataset.name) === letter) {
                r.scrollIntoView({ block: "center", behavior: "smooth" })
                const link = r.querySelector(".row-link")
                if (link) setSelection(link)
                return
            }
        }
    }

    for (const letter of LETTERS) {
        const present = presentSet.has(letter)
        const cls = "rail-letter" + (present ? "" : " disabled")
        const btn = el("button", { className: cls, type: "button", disabled: !present, tabIndex: present ? 0 : -1 }, letter)
        if (present) {
            btn.dataset.letter = letter
            btn.addEventListener("click", (ev) => {
                ev.preventDefault()
                jumpTo(letter)
            })
        }
        rail.append(btn)
    }
    return rail
}

function formatRelative(epochSec) {
    if (!epochSec) return ""
    const diff = Date.now() / 1000 - epochSec
    if (diff < 60) return "just now"
    if (diff < 3600) return `${Math.round(diff / 60)}m ago`
    if (diff < 86400) return `${Math.round(diff / 3600)}h ago`
    if (diff < 86400 * 7) return `${Math.round(diff / 86400)}d ago`
    if (diff < 86400 * 30) return `${Math.round(diff / 86400 / 7)}w ago`
    if (diff < 86400 * 365) return `${Math.round(diff / 86400 / 30)}mo ago`
    return `${Math.round(diff / 86400 / 365)}y ago`
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
    if (window.duplexPlayer?.teardown) window.duplexPlayer.teardown()
    window.duplexPlayer = null
}

// Couch-first remote handler. Always installed in the player view; the
// browser experience uses the exact same key model (it also still responds
// to mouse / spacebar / hover via attachPlayerControls). Layout:
//   • OK / Space / Enter → play/pause (unless something more specific is selected)
//   • Left / Right       → seek ±10s
//   • Up                 → subtitle picker
//   • Down               → audio picker (falls back to subs if single track)
//   • Escape (= Menu)    → close picker if open, else back to browse
function installPlayerRemoteHandler({ video, stage, openSubsPicker, openAudioPicker }) {
    const SEEK_SECONDS = 10
    const showOSD = stage.__duplexShowOSD

    const seek = (delta) => {
        const dur = isFinite(video.duration) ? video.duration : Infinity
        const before = video.currentTime
        video.currentTime = Math.max(0, Math.min(dur, before + delta))
        console.log(`[player] seek ${delta > 0 ? "+" : ""}${delta}s: ${before.toFixed(2)} -> ${video.currentTime.toFixed(2)}`)
    }

    const togglePlay = () => {
        const wasPaused = video.paused
        wasPaused ? video.play() : video.pause()
        console.log(`[player] toggle play: paused ${wasPaused} -> ${!wasPaused} at t=${video.currentTime.toFixed(2)}`)
    }

    const handleKey = (ev) => {
        const k = ev.key
        // When the post-play "Continue" button is the active selection, let
        // spatial nav fire its click on Enter/Space instead of swallowing
        // the key for play/pause.
        if (document.querySelector(".continue-next-btn.selected")) return false
        if (k === " " || k === "Enter") {
            ev.preventDefault()
            togglePlay()
            showOSD()
            return true
        }
        if (k === "ArrowLeft" || k === "ArrowRight") {
            ev.preventDefault()
            seek(k === "ArrowLeft" ? -SEEK_SECONDS : SEEK_SECONDS)
            showOSD()
            return true
        }
        if (k === "ArrowUp") {
            ev.preventDefault()
            openSubsPicker()
            return true
        }
        if (k === "ArrowDown") {
            ev.preventDefault()
            openAudioPicker()
            return true
        }
        if (k === "Escape") {
            ev.preventDefault()
            console.log("[player] Escape -> back to browse")
            if (history.length > 1) history.back()
            else location.hash = "#/browse/"
            return true
        }
        return false
    }

    window.duplexPlayer = { handleKey, teardown: () => {} }
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
            } catch (_) {
                void _
            }
        }
    }
}

function renderSettings() {
    document.documentElement.classList.remove("player-active")
    clearHeaderActions()
    crumbs.innerHTML = ""
    // Render a single "Settings" crumb so the user knows where they are.
    const span = document.createElement("span")
    span.textContent = "settings"
    crumbs.appendChild(document.createElement("span")).className = "sep"
    crumbs.lastChild.textContent = " / "
    crumbs.appendChild(span)

    const positionsCount = Object.keys(readResumeMap()).length
    const lastKeysCount = (() => {
        try {
            let n = 0
            for (let i = 0; i < localStorage.length; i++) {
                const k = localStorage.key(i)
                if (k && k.startsWith("duplex.last:")) n++
            }
            return n
        } catch {
            return 0
        }
    })()

    const positionsRow = settingsRow(
        "Resume positions",
        `${positionsCount} remembered`,
        "Forget all",
        () => {
            if (!confirm(`Forget all ${positionsCount} remembered positions?`)) return
            try {
                localStorage.removeItem(RESUME_KEY)
            } catch (e) {
                console.warn("[settings] failed to clear positions", e)
            }
            render()
        },
        positionsCount === 0
    )
    const selectionsRow = settingsRow(
        "Remembered selections",
        `${lastKeysCount} directories`,
        "Forget all",
        () => {
            if (!confirm(`Forget remembered selection in ${lastKeysCount} directories?`)) return
            try {
                const toRemove = []
                for (let i = 0; i < localStorage.length; i++) {
                    const k = localStorage.key(i)
                    if (k && k.startsWith("duplex.last:")) toRemove.push(k)
                }
                for (const k of toRemove) localStorage.removeItem(k)
            } catch (e) {
                console.warn("[settings] failed to clear selections", e)
            }
            render()
        },
        lastKeysCount === 0
    )

    const page = el(
        "div",
        { className: "settings-page" },
        el("h1", { className: "settings-title" }, "Settings"),
        el("div", { className: "settings-list" }, positionsRow, selectionsRow)
    )
    app.replaceChildren(page)
}

function settingsRow(title, status, actionLabel, onClick, disabled) {
    const btn = el("button", { className: "settings-action", type: "button", disabled: !!disabled }, actionLabel)
    if (!disabled) btn.addEventListener("click", onClick)
    return el(
        "div",
        { className: "settings-row" },
        el(
            "div",
            { className: "settings-row-text" },
            el("div", { className: "settings-row-title" }, title),
            el("div", { className: "settings-row-status" }, status)
        ),
        btn
    )
}

async function renderPlay(path) {
    teardownPlayer()
    clearHeaderActions()
    document.documentElement.classList.add("player-active")
    renderCrumbs(path, "dirs")
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

    // Subtitle options. Always include "Off" as the first entry so the
    // picker has somewhere to land. Sidecars and text-format embedded
    // streams are both surfaced; image-format embedded streams are skipped
    // (we have no renderer for PGS/VobSub on the web client).
    const subOptions = [{ value: "", label: "Off" }]
    info.sidecars?.forEach((s, i) => {
        subOptions.push({ value: "sidecar:" + i, label: `${s.language || "?"} (sidecar ${s.format})` })
    })
    info.embedded_subs?.forEach((s) => {
        if (s.format === "text") {
            subOptions.push({ value: "embedded:" + s.index, label: `${s.language || "?"} (embedded ${s.codec || "text"})` })
        }
    })

    // Audio options. Only meaningful when HLS is in play and there's more
    // than one track — direct play hands the raw file to the browser and we
    // can't switch tracks server-side from there.
    const audioTracks = info.audio_tracks ?? []
    const initialAudioIdx = (() => {
        const enTrack = audioTracks.find((a) => {
            const lang = (a.language || "").toLowerCase()
            return lang === "en" || lang.startsWith("en-") || lang === "eng"
        })
        return (enTrack || audioTracks[0])?.index
    })()
    const audioOptions =
        info.decision !== "direct" && audioTracks.length > 1
            ? audioTracks.map((a, i) => {
                  const lang = a.language || `audio ${i + 1}`
                  const chInfo = a.channel_layout || (a.channels ? `${a.channels}ch` : null)
                  const ch = chInfo ? ` (${chInfo})` : ""
                  return { value: String(a.index), label: `${lang}${ch}` }
              })
            : []

    const labelFor = (opts, val) => opts.find((o) => o.value === val)?.label ?? "?"

    const playBtn = el("button", { className: "ctrl-btn ctrl-play", title: "play/pause" }, "▶")
    const scrub = el("input", { type: "range", className: "ctrl-scrub", min: "0", max: "100", step: "any", value: "0" })
    const timeDisplay = el("span", { className: "ctrl-time" }, "0:00 / 0:00")
    const savedVolume = (() => {
        try {
            return parseFloat(localStorage.getItem("duplex.volume"))
        } catch {
            return NaN
        }
    })()
    const savedMuted = (() => {
        try {
            return localStorage.getItem("duplex.muted") === "1"
        } catch {
            return false
        }
    })()
    const initVolume = isFinite(savedVolume) ? savedVolume : 1
    const muteBtn = el("button", { className: "ctrl-btn ctrl-mute", title: "mute" }, "♪")
    const volumeSlider = el("input", {
        type: "range",
        className: "ctrl-volume",
        min: "0",
        max: "1",
        step: "0.01",
        value: String(initVolume)
    })
    const fsBtn = el("button", { className: "ctrl-btn ctrl-fs", title: "fullscreen" }, "⛶")

    // Picker-opening buttons replace the old inline <select> dropdowns.
    // One UI everywhere: click on desktop, OK on remote, both pop the same
    // modal picker that already exists for tvOS.
    const subBtn = el("button", { className: "ctrl-subs", type: "button", title: "Subtitles" }, "CC Off")
    const audioBtn =
        audioOptions.length > 0
            ? el(
                  "button",
                  { className: "ctrl-audio", type: "button", title: "Audio" },
                  "♪ " + labelFor(audioOptions, String(initialAudioIdx))
              )
            : null

    const controlBar = el(
        "div",
        { className: "player-controls" },
        playBtn,
        scrub,
        timeDisplay,
        muteBtn,
        volumeSlider,
        audioBtn,
        subBtn,
        fsBtn
    )

    // Top-left back button. The page header is hidden during playback so the
    // crumb/home link is gone — without this, a mouse-only user has no way
    // out of a video (and no reason to guess that Esc works). LRUD users can
    // reach it via spatial nav too, but Menu/Escape is the faster path for
    // them.
    const backBtn = el("button", { className: "ctrl-back", type: "button", title: "Back", "aria-label": "Back" }, "← Back")
    backBtn.addEventListener("click", (ev) => {
        ev.preventDefault()
        if (history.length > 1) history.back()
        else location.hash = "#/browse/"
    })

    const stage = el("div", { className: "player-stage" }, video, cueOverlay, backBtn, controlBar)
    const wrap = el("div", { className: "player" }, stage, detailsBlock(info))
    app.replaceChildren(wrap)

    const masterUrlFor = (audioIdx) => `${info.urls.master}${audioIdx !== undefined ? `?audio=${audioIdx}` : ""}`
    let currentAudio = initialAudioIdx
    let currentSubValue = ""

    if (info.decision === "direct") {
        video.src = info.urls.raw
    } else if (window.Hls && window.Hls.isSupported()) {
        const hls = new window.Hls({ debug: false })
        activeHls = hls
        hls.loadSource(masterUrlFor(initialAudioIdx))
        hls.attachMedia(video)
        activeRecovery = installHlsRecovery({
            hls,
            video,
            getMasterUrl: () => masterUrlFor(currentAudio)
        })
    } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = masterUrlFor(initialAudioIdx)
    } else {
        app.replaceChildren(el("div", { className: "error" }, "no HLS support in this browser"))
        return
    }

    // Apply a subtitle choice: tear down any existing <track>, then mount
    // the new one in `hidden` mode so the browser fires cuechange events
    // we can intercept and paint into our own .cue-overlay (the native
    // rendering ignores our font-size + stage-anchored positioning).
    const applySubChoice = (value) => {
        currentSubValue = value
        const label = value ? labelFor(subOptions, value) : "Off"
        subBtn.textContent = "CC " + label
        ;[...video.querySelectorAll("track")].forEach((t) => t.remove())
        cueOverlay.textContent = ""
        if (!value) return
        const t = document.createElement("track")
        t.kind = "subtitles"
        t.default = true
        t.label = label
        t.src = `/api/subs?path=${encodeURIComponent(path)}&track=${encodeURIComponent(value)}`
        t.srclang = "en"
        video.append(t)
        setTimeout(() => {
            ;[...video.textTracks].forEach((tt) => {
                tt.mode = "hidden"
                tt.oncuechange = () => {
                    const active = [...(tt.activeCues || [])]
                    cueOverlay.textContent = active.map((c) => c.text).join("\n")
                }
            })
        }, 50)
    }

    // Apply an audio choice: hls.js gets a new master URL; native HLS
    // (Safari, tvOS UIWebView) can't swap tracks via API so we reload the
    // whole source with the audio query param and seek back to position.
    const applyAudioChoice = (value) => {
        const audioIdx = parseInt(value, 10)
        if (audioIdx === currentAudio) return
        const curTime = video.currentTime
        const wasPlaying = !video.paused
        console.log(`[audio] switch ${currentAudio} -> ${audioIdx} at t=${curTime.toFixed(2)}`)
        currentAudio = audioIdx
        if (audioBtn) audioBtn.textContent = "♪ " + labelFor(audioOptions, value)
        if (activeRecovery) activeRecovery.notePosition(curTime)
        const newUrl = masterUrlFor(audioIdx)
        if (activeHls) {
            activeHls.loadSource(newUrl)
        } else {
            video.src = newUrl
            video.load()
        }
        video.addEventListener("canplay", function onCanPlay() {
            video.removeEventListener("canplay", onCanPlay)
            video.currentTime = curTime
            if (wasPlaying) video.play()
        })
    }

    const openSubsPicker = () => {
        const idx = Math.max(
            0,
            subOptions.findIndex((o) => o.value === currentSubValue)
        )
        openPicker({
            title: "Subtitles",
            options: subOptions,
            currentIndex: idx,
            onSelect: (opt) => applySubChoice(opt.value)
        })
    }

    const openAudioPicker = () => {
        if (audioOptions.length === 0) {
            openSubsPicker()
            return
        }
        const idx = Math.max(
            0,
            audioOptions.findIndex((o) => o.value === String(currentAudio))
        )
        openPicker({
            title: "Audio",
            options: audioOptions,
            currentIndex: idx,
            onSelect: (opt) => applyAudioChoice(opt.value)
        })
    }

    subBtn.addEventListener("click", openSubsPicker)
    if (audioBtn) audioBtn.addEventListener("click", openAudioPicker)

    video.volume = initVolume
    video.muted = savedMuted
    attachPlayerControls({ video, stage, playBtn, scrub, timeDisplay, muteBtn, volumeSlider, fsBtn, path })
    // One UI everywhere — couch-first. Arrow keys always seek; Up/Down
    // always open the sub/audio pickers; OK on the focused element fires
    // its click. Mouse / hover / wheel still work because the controls are
    // real elements with their own click handlers.
    installPlayerRemoteHandler({ video, stage, openSubsPicker, openAudioPicker })
}

// Wires every custom control to the <video> element and handles
// auto-hide. Bidirectional: input events drive the video, video events
// (timeupdate, volumechange, play, pause, …) keep the controls in sync,
// so the controls stay correct even when the user pauses via spacebar,
// the browser autoplays, or fullscreen is exited via Esc.
// When a video naturally ends (including a scrub-to-end), ask the server
// what would play next in the same directory and surface a single
// "Continue → <name>" button. Lightweight by design: no countdown, no
// auto-play, no playlist queue — just one click/OK and we navigate.
async function maybeShowContinueNext({ stage, path }) {
    if (!path) return
    let data
    try {
        const r = await fetch("/api/next?path=" + encodeURIComponent(path))
        if (r.status === 404) return
        if (!r.ok) {
            console.warn("[next] fetch failed", r.status)
            return
        }
        data = await r.json()
    } catch (e) {
        console.warn("[next] fetch threw", e)
        return
    }
    // Already showing one? Replace it (avoid stacking on re-end).
    const old = stage.querySelector(".continue-next")
    if (old) old.remove()

    const btn = el(
        "a",
        { className: "continue-next-btn", href: "#/play/" + encodePath(data.vpath) },
        el("div", { className: "continue-next-arrow" }, "▶"),
        el(
            "div",
            { className: "continue-next-meta" },
            el("div", { className: "continue-next-label" }, "Continue"),
            el("div", { className: "continue-next-name" }, data.name)
        )
    )
    const overlay = el("div", { className: "continue-next" }, btn)
    stage.append(overlay)
    // Make sure spatial-nav and the player key handler both pick the button
    // as the active target; OK/Enter should fire the navigate.
    setSelection(btn)
    console.log(`[next] showing Continue → ${data.vpath}`)
}

function attachPlayerControls({ video, stage, playBtn, scrub, timeDisplay, muteBtn, volumeSlider, fsBtn, path }) {
    let scrubbing = false
    let resumed = false
    // Restore prior position on first loadedmetadata. We only do this once per
    // mount — later metadata events (audio-track swaps reload the source and
    // we seek back manually in that flow) shouldn't re-trigger restore.
    const tryResume = () => {
        if (resumed || !path) return
        const entry = getResume(path)
        if (!entry) {
            resumed = true
            return
        }
        if (entry.pos > 0 && isFinite(video.duration) && entry.pos < video.duration) {
            console.log(`[resume] restoring "${path}" to ${entry.pos.toFixed(1)}s`)
            video.currentTime = entry.pos
        }
        resumed = true
    }
    video.addEventListener("loadedmetadata", tryResume)
    if (video.readyState >= 1) tryResume()

    // Heartbeat: persist every HEARTBEAT_MS while playing, plus on pause and
    // on any scrub committal. setResume() handles the "first 5s / last 5%"
    // edge cases by clearing rather than writing.
    const HEARTBEAT_MS = 5000
    let lastPersistAt = 0
    const persistNow = () => {
        if (!path) return
        const dur = video.duration
        if (!isFinite(dur) || dur <= 0) return
        setResume(path, video.currentTime, dur)
        lastPersistAt = performance.now()
    }
    const maybePersist = () => {
        if (performance.now() - lastPersistAt > HEARTBEAT_MS) persistNow()
    }
    video.addEventListener("ended", async () => {
        if (path) clearResume(path)
        await maybeShowContinueNext({ stage, path })
    })

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
        maybePersist()
    })
    video.addEventListener("pause", persistNow)
    scrub.addEventListener("input", () => {
        scrubbing = true
        timeDisplay.textContent = `${fmtTime(parseFloat(scrub.value))} / ${fmtTime(video.duration)}`
    })
    scrub.addEventListener("change", () => {
        video.currentTime = parseFloat(scrub.value)
        scrubbing = false
        persistNow()
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
        try {
            localStorage.setItem("duplex.volume", String(video.volume))
            localStorage.setItem("duplex.muted", video.muted ? "1" : "0")
        } catch (e) {
            void e
        }
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

    // OSD auto-hide. Same policy everywhere: a fixed dwell after the last
    // input or paint, then dim and drop selection. Mouse moves / hover /
    // pause / remote presses all re-surface via showControls. The video's
    // `paused` flag can't be trusted (UIWebView reports stale `true` while
    // audio/video keep advancing) so the timer fires regardless.
    let hideTimer = null
    const HIDE_MS = 3500
    const showControls = () => {
        stage.classList.add("show-controls")
        if (hideTimer) {
            clearTimeout(hideTimer)
            hideTimer = null
        }
        hideTimer = setTimeout(() => {
            stage.classList.remove("show-controls")
            const sel = document.querySelector(".selected")
            if (sel) sel.classList.remove("selected")
        }, HIDE_MS)
    }
    stage.addEventListener("mousemove", showControls)
    stage.addEventListener("mouseenter", showControls)
    stage.addEventListener("mouseleave", () => {
        if (!video.paused) stage.classList.remove("show-controls")
    })
    video.addEventListener("pause", showControls)
    // Start with the OSD hidden so the video opens full-bleed; any input
    // surfaces it. The remote handler calls showOSD on every keypress.

    // Expose hooks the player keydown handler needs.
    stage.__duplexShowOSD = showControls
    stage.__duplexIsOSDVisible = () => stage.classList.contains("show-controls")

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
    // Always tear down any picker and the previous player before swapping
    // routes — teardownPlayer also nulls window.duplexPlayer so leftover
    // key handlers don't keep firing in the next view.
    closeOpenPicker()
    if (r.kind !== "play") teardownPlayer()
    if (r.kind === "play") renderPlay(r.path)
    else if (r.kind === "settings") renderSettings()
    else renderBrowse(r.path)
    // Intentionally not auto-selecting anything — the spatial-nav highlight
    // only appears once the user presses an arrow key.
}

// Spatial keyboard navigation for TV-style remotes (Siri Remote, etc.). The
// tvOS wrapper synthesizes Arrow/Space/Enter KeyboardEvents on document.
// We can't rely on DOM focus + `:focus` CSS — UIWebView's older WebKit on
// tvOS does not reliably paint focus rings on anchors. Instead we manage
// selection ourselves: tag the chosen element with `.selected`, style that
// class loudly, and on Enter call .click(). Approach borrowed from
// ~/work/movienight which hit the same wall.
const SELECTABLE_SELECTOR = [
    "a[href]",
    "button:not([disabled])",
    'input:not([disabled]):not([type="hidden"])',
    "select:not([disabled])",
    "textarea:not([disabled])",
    "[data-selectable]"
].join(",")

function isVisible(el) {
    if (!el.isConnected) return false
    if (!el.offsetParent && getComputedStyle(el).position !== "fixed") return false
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0
}

function selectables() {
    return Array.from(document.querySelectorAll(SELECTABLE_SELECTOR)).filter(isVisible)
}

function currentSelection() {
    return document.querySelector(".selected")
}

function setSelection(el) {
    const prev = currentSelection()
    if (prev === el) return
    if (prev) prev.classList.remove("selected")
    if (el) {
        el.classList.add("selected")
        el.scrollIntoView({ block: "nearest", inline: "nearest" })
        console.log(`[nav] setSelection:`, el)
    }
}

function pickNeighbor(dir) {
    const all = selectables()
    if (all.length === 0) return null
    const cur = currentSelection()
    if (!cur || !all.includes(cur)) return all[0]
    const sr = cur.getBoundingClientRect()
    const scx = sr.left + sr.width / 2
    const scy = sr.top + sr.height / 2
    let best = null
    let bestScore = Infinity
    for (const el of all) {
        if (el === cur) continue
        const r = el.getBoundingClientRect()
        const cx = r.left + r.width / 2
        const cy = r.top + r.height / 2
        let primary, perpend
        if (dir === "down") {
            if (r.top < sr.bottom - 1) continue
            primary = cy - scy
            perpend = cx - scx
        } else if (dir === "up") {
            if (r.bottom > sr.top + 1) continue
            primary = scy - cy
            perpend = cx - scx
        } else if (dir === "right") {
            if (r.left < sr.right - 1) continue
            primary = cx - scx
            perpend = cy - scy
        } else {
            if (r.right > sr.left + 1) continue
            primary = scx - cx
            perpend = cy - scy
        }
        if (primary <= 0) continue
        // Weight perpendicular distance heavily — prefer items in line with
        // the current selection over closer-but-diagonal ones.
        const score = primary * primary + 4 * perpend * perpend
        if (score < bestScore) {
            bestScore = score
            best = el
        }
    }
    return best
}

function moveSelection(dir) {
    const n = pickNeighbor(dir)
    if (!n) return false
    setSelection(n)
    return true
}

// Modal list picker for tvOS-style choice screens (subtitle / audio track).
// Stays open until user picks an item or hits Escape. While open, swallows
// all relevant keys so neither the player nor spatial-nav reacts.
function openPicker({ title, options, currentIndex, onSelect, onCancel }) {
    closeOpenPicker()
    if (!options || options.length === 0) return null

    const overlay = el("div", { className: "duplex-picker" })
    const card = el("div", { className: "picker-card" })
    overlay.append(card)
    if (title) card.append(el("div", { className: "picker-title" }, title))
    const list = el("div", { className: "picker-list" })
    card.append(list)
    document.body.append(overlay)

    let idx = Math.max(0, Math.min(options.length - 1, currentIndex ?? 0))
    const render = () => {
        list.replaceChildren()
        options.forEach((opt, i) => {
            const item = el("div", { className: "picker-item" + (i === idx ? " selected" : "") }, opt.label)
            item.addEventListener("click", () => {
                idx = i
                commit("select")
            })
            list.append(item)
        })
        const selEl = list.querySelector(".selected")
        if (selEl) selEl.scrollIntoView({ block: "nearest" })
    }

    const commit = (action) => {
        if (window.duplexPicker !== api) return
        window.duplexPicker = null
        overlay.remove()
        if (action === "select") onSelect?.(options[idx], idx)
        else onCancel?.()
    }

    const handleKey = (ev) => {
        const k = ev.key
        if (k === "ArrowUp") {
            idx = (idx - 1 + options.length) % options.length
            render()
        } else if (k === "ArrowDown") {
            idx = (idx + 1) % options.length
            render()
        } else if (k === "Enter" || k === " ") {
            commit("select")
        } else if (k === "Escape") {
            commit("cancel")
        } else {
            return false
        }
        return true
    }

    const api = { handleKey, close: () => commit("cancel") }
    window.duplexPicker = api
    render()
    console.log(`[picker] open "${title}" (${options.length} options, current=${idx})`)
    return api
}

function closeOpenPicker() {
    if (window.duplexPicker) window.duplexPicker.close()
}

const ARROW_DIRS = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" }

function describeEl(el) {
    if (!el) return "<none>"
    const id = el.id ? "#" + el.id : ""
    const cls =
        el.className && typeof el.className === "string"
            ? "." + el.className.split(/\s+/).filter(Boolean).slice(0, 2).join(".")
            : ""
    const txt = (el.textContent || "").trim().slice(0, 30)
    return `<${el.tagName.toLowerCase()}${id}${cls} "${txt}">`
}

document.addEventListener(
    "keydown",
    (ev) => {
        // Priority 1: a modal picker is open — it owns every relevant key
        // until the user picks or cancels. stopImmediatePropagation keeps
        // bubble-phase listeners (e.g. the legacy Space=play/pause hook in
        // attachPlayerControls) from acting on the same event.
        if (window.duplexPicker) {
            if (window.duplexPicker.handleKey(ev)) {
                ev.preventDefault()
                ev.stopImmediatePropagation()
            }
            return
        }
        // Priority 2: TV-mode player owns its keys (play/pause, seek,
        // sub/audio pickers, back). Same stop-propagation rationale.
        if (window.duplexPlayer?.handleKey?.(ev)) {
            ev.stopImmediatePropagation()
            return
        }
        // Priority 3: spatial navigation in browse view (and the player in
        // browser mode, where window.duplexPlayer is never installed).
        if (ev.key === "Escape") {
            ev.preventDefault()
            if (history.length > 1) history.back()
            else location.reload()
            return
        }
        const dir = ARROW_DIRS[ev.key]
        if (dir) {
            const before = describeEl(currentSelection())
            const moved = moveSelection(dir)
            const after = describeEl(currentSelection())
            console.log(`[nav] ${dir} moved=${moved} ${before} -> ${after} (selectables=${selectables().length})`)
            if (moved) ev.preventDefault()
            return
        }
        if (ev.key === "Enter" || ev.key === " ") {
            const s = currentSelection()
            if (!s) return
            const clickable = s.tagName === "A" || s.tagName === "BUTTON"
            if (ev.key === " " && !clickable) return
            console.log(`[nav] ${ev.key === " " ? "Space" : "Enter"} clicking ${describeEl(s)}`)
            if (typeof s.click === "function") {
                ev.preventDefault()
                s.click()
            }
        }
    },
    true
)

window.addEventListener("hashchange", render)
window.addEventListener("DOMContentLoaded", () => {
    if (!location.hash) location.hash = "#/browse/"
    render()
})
