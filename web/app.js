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

// Smoke test for the --js-logs pipeline. Gated behind ?smoketest=1 so default
// boots stay quiet; visit /?smoketest=1 to re-prove the full chain end-to-end.
if (window.__DUPLEX_CONFIG__?.jsLogs && new URLSearchParams(location.search).get("smoketest") === "1") {
    console.log("[smoke] console.log from app boot")
    console.info("[smoke] console.info from app boot")
    console.warn("[smoke] console.warn from app boot")
    console.error("[smoke] console.error with Error", new Error("smoke error"))
    setTimeout(() => {
        throw new Error("[smoke] setTimeout throw")
    }, 0)
    Promise.reject(new Error("[smoke] unhandled rejection"))
}

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

// Per-video track preferences. Map of vpath -> {audio, sub}. `audio` is the
// 0-based ordinal into the manifest's audio_tracks; `sub` is the web subtitle
// value string ("" for Off, "sidecar:N" for a sidecar). Remembered so the
// next play of the same file restores the user's last audio/subtitle choice,
// mirroring the tvOS TrackPrefsStore.
const TRACKPREFS_KEY = "duplex.trackPrefs"

function readTrackPrefsMap() {
    try {
        return JSON.parse(localStorage.getItem(TRACKPREFS_KEY) || "{}") || {}
    } catch {
        return {}
    }
}
function writeTrackPrefsMap(m) {
    try {
        localStorage.setItem(TRACKPREFS_KEY, JSON.stringify(m))
    } catch (e) {
        console.warn("[trackPrefs] write failed", e)
    }
}
function getTrackPrefs(path) {
    return readTrackPrefsMap()[path] || null
}
function setTrackPref(path, key, value) {
    if (!path) return
    const m = readTrackPrefsMap()
    const prefs = m[path] || {}
    prefs[key] = value
    m[path] = prefs
    writeTrackPrefsMap(m)
}

// Binges. An explicit, ordered watch-queue the user creates from a folder:
// a flattened list of video vpaths played in sequence. `vpaths[0]` is always
// "what plays next"; finishing a video pops it, and an empty queue deletes
// the binge. Persisted under `duplex.binges`, mirroring the tvOS BingeStore.
const BINGES_KEY = "duplex.binges"

function newId() {
    // crypto.randomUUID needs a secure context (https/localhost); Duplex is
    // often served over plain http on a LAN, so fall back to a cheap unique id.
    return crypto?.randomUUID?.() ?? Date.now().toString(36) + Math.random().toString(36).slice(2)
}
function readBinges() {
    try {
        const v = JSON.parse(localStorage.getItem(BINGES_KEY) || "[]")
        return Array.isArray(v) ? v : []
    } catch {
        return []
    }
}
function writeBinges(arr) {
    try {
        localStorage.setItem(BINGES_KEY, JSON.stringify(arr))
    } catch (e) {
        console.warn("[binge] write failed", e)
    }
}
// Newest first.
function bingesOrdered() {
    return readBinges().sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0))
}
function bingeById(id) {
    return readBinges().find((b) => b.id === id) || null
}
// Every binge whose next-up video is exactly `vpath` — powers the chooser
// interception when a binge's front is played from somewhere else.
function bingesWithFront(vpath) {
    return readBinges().filter((b) => b.vpaths?.[0] === vpath)
}
function createBinge(origin, vpaths) {
    if (!vpaths || vpaths.length === 0) return null
    const binge = { id: newId(), origin, vpaths, createdAt: Date.now() }
    const all = readBinges()
    all.push(binge)
    writeBinges(all)
    console.log(`[binge] created ${binge.id} origin=${origin} count=${vpaths.length}`)
    return binge
}
// Advance a binge past `vpath`, but only while `vpath` is still its front —
// idempotent, so the natural-end and back-out callers can't double-pop.
// Removes the binge once its queue empties.
function popBingeFrontIfMatches(id, vpath) {
    const all = readBinges()
    const idx = all.findIndex((b) => b.id === id)
    if (idx < 0 || all[idx].vpaths?.[0] !== vpath) return
    all[idx].vpaths.shift()
    if (all[idx].vpaths.length === 0) {
        console.log(`[binge] exhausted ${id} — removing`)
        all.splice(idx, 1)
    } else {
        console.log(`[binge] popped ${id}, now front=${all[idx].vpaths[0]} remaining=${all[idx].vpaths.length}`)
    }
    writeBinges(all)
}
function removeBinge(id) {
    const all = readBinges().filter((b) => b.id !== id)
    writeBinges(all)
    console.log(`[binge] deleted ${id}`)
}

// Advance the bound binge when the video is effectively done. `finished` is
// true on a natural end; on back-out we apply the "≥95% watched" rule against
// the last known position. No-op when playback isn't bound to a binge.
function maybeAdvanceBinge({ bingeId, path, finished, video }) {
    if (!bingeId) return
    const dur = video?.duration
    const pos = video?.currentTime
    const watchedEnough = finished || (isFinite(dur) && dur > 0 && isFinite(pos) && pos >= dur * 0.95)
    if (!watchedEnough) return
    popBingeFrontIfMatches(bingeId, path)
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
    // Search query is a single whole-string-encoded segment (may contain "/").
    const sm = h.match(/^\/search\/(.*)$/)
    if (sm) return { kind: "search", query: decodeURIComponent(sm[1] || "") }
    const m = h.match(/^\/(browse|play)\/(.*)$/)
    if (!m) return { kind: "browse", path: "" }
    let rest = m[2] || ""
    // Optional query suffix on the play route carries the binge binding:
    //   #/play/<path>?binge=<id>   — finishing advances that binge
    //   #/play/<path>?binge=none   — explicitly "just play it" (skip chooser)
    let bingeId = null
    const qIdx = rest.indexOf("?")
    if (qIdx >= 0) {
        bingeId = new URLSearchParams(rest.slice(qIdx + 1)).get("binge")
        rest = rest.slice(0, qIdx)
    }
    const path = rest.split("/").map(decodeURIComponent).filter(Boolean).join("/")
    return { kind: m[1], path, bingeId }
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

    // Binges and Continue Watching are always rendered (even when empty) so
    // deleting the last entry doesn't reflow the other columns. The empty
    // states double as discovery.
    columns.append(renderBingesColumn())
    columns.append(renderContinueColumn())

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
// Strip trailing video extensions for display only. Filenames on disk and
// in the API (entry.name, vpath, dataset.name) keep the extension.
function displayName(name) {
    return name.replace(/\.(mp4|mkv)$/i, "")
}

function makeBrowseRow(entry, vpath) {
    const isDir = entry.kind === "dir"
    const href = isDir ? "#/browse/" + encodePath(vpath) : "#/play/" + encodePath(vpath)
    const icon = el("span", { className: "row-icon" }, isDir ? "📁" : "🎬")
    const name = el("div", { className: "row-name" }, isDir ? entry.name : displayName(entry.name))
    if (!isDir && entry.codec_hint) name.append(el("span", { className: "badge " + entry.codec_hint }, entry.codec_hint))
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
    if (isDir) row.append(bingeButton(vpath))
    row.dataset.name = entry.name
    return row
}

// Trailing "🍿" action on a folder row — the mouse analog of tvOS's hold-✓.
// Flattens the folder server-side, confirms, and creates a binge.
function bingeButton(vpath) {
    const btn = el(
        "button",
        { className: "row-action row-binge", type: "button", title: "Binge this folder", "aria-label": "Binge this folder" },
        "🍿"
    )
    btn.addEventListener("click", (ev) => {
        ev.preventDefault()
        ev.stopPropagation()
        startBinge(vpath)
    })
    return btn
}

// Flatten `originVpath`, confirm, and create a binge. Re-renders the root so
// the new binge appears when the user is creating from the Libraries column.
async function startBinge(originVpath) {
    let data
    try {
        data = await getJSON("/api/flatten?path=" + encodeURIComponent(originVpath))
    } catch (e) {
        alert("Couldn't build binge: " + e.message)
        return
    }
    const vpaths = data.vpaths || []
    if (vpaths.length === 0) {
        alert(`There are no videos in ${basenameOf(originVpath)}.`)
        return
    }
    if (!confirm(`Binge “${data.origin}”?\n${vpaths.length} ${vpaths.length === 1 ? "video" : "videos"} will be queued.`)) return
    createBinge(data.origin, vpaths)
    const r = parseRoute()
    if (r.kind === "browse" && r.path === "") render()
}

// "Continue Watching" column: vertical list of rows, each with a small
// inline "✕" remove button. Always renders the column wrapper, even with
// zero entries — an empty state replaces the list so deleting the last
// item doesn't reflow the other root columns.
function renderContinueColumn() {
    const items = continueItems()
    const list = el("ul", { className: "col-list" })
    const section = el("section", { className: "col col-continue" }, columnHeader("Continue Watching"), list)

    if (items.length === 0) {
        list.append(
            el(
                "li",
                { className: "col-empty-state" },
                el("div", { className: "empty-state-icon" }, "🍿"),
                el("div", { className: "empty-state-title" }, "Nothing in progress"),
                el("div", { className: "empty-state-hint" }, "Play something and pick up where you left off")
            )
        )
        return section
    }

    const rebuild = () => {
        const fresh = renderContinueColumn()
        section.replaceWith(fresh)
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
                el("div", { className: "row-name" }, displayName(basename)),
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
        const isDir = it.kind === "dir"
        const href = (isDir ? "#/browse/" : "#/play/") + encodePath(it.vpath)
        const metaLeft = isDir ? `${it.children} ${it.children === 1 ? "entry" : "entries"}` : prettySize(it.size)
        const link = el(
            "a",
            { className: "row-link " + (isDir ? "row-dir" : "row-file"), href },
            el("span", { className: "row-icon" }, isDir ? "📁" : "🎬"),
            el(
                "div",
                { className: "row-text" },
                parent ? el("div", { className: "row-context" }, parent) : null,
                el("div", { className: "row-name" }, isDir ? basename : displayName(basename)),
                el("div", { className: "row-meta" }, `${metaLeft} · ${formatRelative(it.mtime)}`)
            )
        )
        const row = el("li", { className: "col-row" }, link)
        if (isDir) row.append(bingeButton(it.vpath))
        row.dataset.name = basename
        list.append(row)
    }
}

// "Binges" column: each binge shows its origin, next-up video, and remaining
// count; clicking plays the front bound to the binge so finishing it advances
// the queue. A trailing ✕ deletes the binge (with confirm). Always rendered,
// even when empty, so deleting the last one doesn't reflow the root columns.
function renderBingesColumn() {
    const binges = bingesOrdered()
    const list = el("ul", { className: "col-list" })
    const section = el("section", { className: "col col-binges" }, columnHeader("Binges"), list)

    if (binges.length === 0) {
        list.append(
            el(
                "li",
                { className: "col-empty-state" },
                el("div", { className: "empty-state-icon" }, "🍿"),
                el("div", { className: "empty-state-title" }, "No binges yet"),
                el("div", { className: "empty-state-hint" }, "Hit 🍿 on a folder to queue everything in it")
            )
        )
        return section
    }

    const rebuild = () => section.replaceWith(renderBingesColumn())

    for (const b of binges) {
        const front = b.vpaths[0]
        const leaf = front ? front.split("/").pop() : ""
        const link = el(
            "a",
            { className: "row-link row-file", href: "#/play/" + encodePath(front) + "?binge=" + encodeURIComponent(b.id) },
            el("span", { className: "row-icon" }, "🍿"),
            el(
                "div",
                { className: "row-text" },
                el("div", { className: "row-context" }, b.origin),
                el("div", { className: "row-name" }, displayName(leaf)),
                el("div", { className: "row-meta" }, `${b.vpaths.length} remaining`)
            )
        )
        const removeBtn = el(
            "button",
            { className: "row-action", type: "button", title: "Delete this binge", "aria-label": "Delete binge" },
            "✕"
        )
        removeBtn.addEventListener("click", (ev) => {
            ev.preventDefault()
            ev.stopPropagation()
            if (!confirm(`Delete this binge?\n${b.origin}\n${b.vpaths.length} remaining. This can't be undone.`)) return
            removeBinge(b.id)
            rebuild()
        })
        const row = el("li", { className: "col-row col-row-continue" }, link, removeBtn)
        row.dataset.name = leaf
        list.append(row)
    }
    return section
}

// Shown when a video is played outside a binge but happens to be the next-up
// video of one or more binges: attach this playback to a binge (so finishing
// advances the queue) or play it unattached. Mirrors the tvOS BingeChooserView.
function renderBingeChooser(path) {
    document.documentElement.classList.remove("player-active")
    clearHeaderActions()
    renderCrumbs(path, "dirs")
    const matches = bingesWithFront(path)
    if (matches.length === 0) {
        // Raced away under us — just play it.
        location.replace("#/play/" + encodePath(path) + "?binge=none")
        return
    }
    const leaf = displayName(path.split("/").pop() || path)
    const buttons = matches.map((b) =>
        el(
            "button",
            {
                className: "chooser-binge",
                type: "button",
                onclick: () => {
                    location.hash = "#/play/" + encodePath(path) + "?binge=" + encodeURIComponent(b.id)
                }
            },
            el("span", { className: "chooser-binge-arrow" }, "▶"),
            el(
                "div",
                { className: "chooser-binge-meta" },
                el("div", { className: "chooser-binge-label" }, "Continue binge"),
                el("div", { className: "chooser-binge-origin" }, b.origin),
                el("div", { className: "chooser-binge-remaining" }, `${b.vpaths.length} remaining`)
            )
        )
    )
    const playPlain = el(
        "button",
        {
            className: "chooser-plain",
            type: "button",
            onclick: () => {
                location.hash = "#/play/" + encodePath(path) + "?binge=none"
            }
        },
        "This isn’t part of a binge — just play it"
    )
    const card = el(
        "div",
        { className: "chooser-card" },
        el("div", { className: "chooser-icon" }, "🍿"),
        el("h1", { className: "chooser-title" }, "Continue a binge?"),
        el("div", { className: "chooser-sub" }, leaf),
        el("div", { className: "chooser-actions" }, ...buttons, playPlain)
    )
    app.replaceChildren(el("div", { className: "chooser" }, card))
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

let activeVideo = null
// What's currently playing, for the binge back-out rule. Set in renderPlay.
let activePlay = null

function teardownPlayer() {
    // Back-out path for the binge rule: if the user leaves with ≥95% watched,
    // advance the binge here (idempotent with the natural-end pop). Must run
    // before dispose() while the controller's position is still valid.
    if (activePlay) {
        try {
            maybeAdvanceBinge({ ...activePlay, finished: false })
        } catch (e) {
            console.warn("[binge] back-out advance threw", e)
        }
        activePlay = null
    }
    // The WebCodecs player owns its decoders, Mediabunny input, AudioContext,
    // and canvas — disposing the controller releases all of it. Synchronous
    // from the caller's perspective; the underlying close()s are best-effort
    // and run to completion in the background.
    if (activeVideo) {
        try {
            activeVideo.dispose?.()
        } catch (e) {
            console.warn("[player] teardown threw", e)
        }
        activeVideo = null
    }
    if (window.duplexPlayer?.teardown) window.duplexPlayer.teardown()
    window.duplexPlayer = null
}

// Desktop keyboard shortcuts for the player. The video is mouse-driven
// (controls bar, scrub, click-to-pause), but these keys mirror what every
// other web player offers:
//   • Space / Enter → play/pause
//   • Left / Right  → seek ±10s
//   • Escape        → back to browse
// Subtitle / audio pickers are click-only (the CC / ♪ buttons in the OSD).
function installPlayerKeyHandler({ video, stage }) {
    const SEEK_SECONDS = 10
    const showOSD = stage.__duplexShowOSD

    const back = () => {
        if (history.length > 1) history.back()
        else location.hash = "#/browse/"
    }

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
        // While the end-of-video "Continue" overlay is up, the focused anchor
        // owns Enter/Space (native navigation); Escape still backs out.
        const continueBtn = stage.querySelector(".continue-next-btn")
        if (continueBtn) {
            if (k === "Enter" || k === " ") {
                ev.preventDefault()
                continueBtn.click()
                return true
            }
            if (k === "Escape") {
                ev.preventDefault()
                back()
                return true
            }
            return false
        }
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
        if (k === "Escape") {
            ev.preventDefault()
            console.log("[player] Escape -> back to browse")
            back()
            return true
        }
        return false
    }

    window.duplexPlayer = { handleKey, teardown: () => {} }
}

// One result row for search (and reused shape as Recently Added): a parent
// context line above the name so identically-named episodes are
// distinguishable.
function makeResultRow(item) {
    const parts = item.vpath.split("/")
    const basename = parts.pop()
    const parent = parts.join(" / ")
    const isDir = item.kind === "dir"
    const href = (isDir ? "#/browse/" : "#/play/") + encodePath(item.vpath)
    const metaLeft = isDir ? `${item.children} ${item.children === 1 ? "entry" : "entries"}` : prettySize(item.size)
    const link = el(
        "a",
        { className: "row-link " + (isDir ? "row-dir" : "row-file"), href },
        el("span", { className: "row-icon" }, isDir ? "📁" : "🎬"),
        el(
            "div",
            { className: "row-text" },
            parent ? el("div", { className: "row-context" }, parent) : null,
            el("div", { className: "row-name" }, isDir ? basename : displayName(basename)),
            el("div", { className: "row-meta" }, `${metaLeft} · ${formatRelative(item.mtime)}`)
        )
    )
    const row = el("li", { className: "col-row" }, link)
    row.dataset.name = basename
    return row
}

async function renderSearch(query) {
    document.documentElement.classList.remove("player-active")
    clearHeaderActions()
    crumbs.replaceChildren()
    const q = (query || "").trim()
    crumbs.append(el("span", { className: "crumb-static" }, q ? `Search: “${q}”` : "Search"))
    if (!q) {
        app.replaceChildren(el("p", { className: "muted" }, "Type to search your libraries."))
        return
    }
    app.replaceChildren(el("p", { className: "muted" }, "searching…"))
    let data
    try {
        data = await getJSON("/api/search?q=" + encodeURIComponent(q) + "&limit=50")
    } catch (e) {
        app.replaceChildren(el("div", { className: "error" }, "search failed: " + e.message))
        return
    }
    const items = data.items || []
    const list = el("ul", { className: "col-list" })
    if (items.length === 0) {
        list.append(el("li", { className: "col-empty" }, "No results"))
    } else {
        for (const item of items) list.append(makeResultRow(item))
    }
    const col = el(
        "section",
        { className: "col col-subdir" },
        columnHeader(`Results for “${q}”`),
        el("div", { className: "col-body" }, list)
    )
    app.replaceChildren(el("div", { className: "columns columns-subdir" }, col))
}

// Keep the always-visible header search box in sync with the route. Skipped
// while the user is actively typing (the box is the source of truth then).
function syncSearchBox() {
    const box = document.getElementById("search-box")
    if (!box) return
    const r = parseRoute()
    const q = r.kind === "search" ? r.query : ""
    if (document.activeElement !== box && box.value !== q) box.value = q
}

// Debounced navigation as the user types. Editing within an existing search
// replaces the history entry so Back doesn't step through every keystroke;
// the first keystroke from another view pushes one entry so Back returns
// there. Clearing the box returns to the browse root.
function wireSearchBox() {
    const box = document.getElementById("search-box")
    if (!box) return
    let timer = null
    const go = () => {
        const q = box.value.trim()
        const target = q ? "#/search/" + encodeURIComponent(q) : "#/browse/"
        if (location.hash === target) return
        if (parseRoute().kind === "search") {
            history.replaceState(null, "", target)
            render()
        } else {
            location.hash = target
        }
    }
    box.addEventListener("input", () => {
        clearTimeout(timer)
        timer = setTimeout(go, 220)
    })
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
    const trackPrefsCount = Object.keys(readTrackPrefsMap()).length
    const trackPrefsRow = settingsRow(
        "Track preferences",
        `${trackPrefsCount} remembered`,
        "Forget all",
        () => {
            if (!confirm(`Forget audio/subtitle preferences for ${trackPrefsCount} videos?`)) return
            try {
                localStorage.removeItem(TRACKPREFS_KEY)
            } catch (e) {
                console.warn("[settings] failed to clear track prefs", e)
            }
            render()
        },
        trackPrefsCount === 0
    )

    const page = el(
        "div",
        { className: "settings-page" },
        el("h1", { className: "settings-title" }, "Settings"),
        el("div", { className: "settings-list" }, positionsRow, trackPrefsRow)
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

async function renderPlay(path, bingeId = null) {
    teardownPlayer()
    clearHeaderActions()
    document.documentElement.classList.add("player-active")
    renderCrumbs(path, "dirs")
    app.replaceChildren(el("p", null, "loading…"))
    let info
    try {
        info = await getJSON("/api/manifest?path=" + encodeURIComponent(path))
    } catch (e) {
        app.replaceChildren(el("div", { className: "error" }, "load failed: " + e.message))
        return
    }

    if (!info.video_tracks?.length) {
        app.replaceChildren(el("div", { className: "error" }, "no video track in this file"), detailsBlock(info))
        return
    }

    // The canvas + audio graph live inside `host`; the controller exposes a
    // <video>-shaped API (currentTime, paused, addEventListener…) so the
    // existing controls bar plumbing in attachPlayerControls stays as-is.
    const host = el("div", { className: "player-host" })
    const cueOverlay = el("div", { className: "cue-overlay" })

    // Sidecar subtitles (sibling .srt/.vtt/.ass) are fully supported: fetched
    // raw via /api/sidecar and parsed client-side. Embedded subtitle tracks
    // (mov_text/subrip inside the container) are NOT yet supported because
    // Mediabunny doesn't currently expose subtitle tracks for reading; we
    // inventory them in the manifest but hide them from the picker. Image-
    // based subs (PGS/VobSub) were never supported.
    const subOptions = [{ value: "", label: "Off" }]
    info.sidecars?.forEach((s, i) => {
        const lang = s.language || "Subtitle"
        subOptions.push({ value: "sidecar:" + i, label: `${lang} (${s.format})` })
    })

    // Audio options. Multi-track switching is implemented in a later phase;
    // for now the picker is shown when >1 track exists but only displays the
    // initial selection.
    // Audio tracks are addressed by ORDINAL (0-based index into the
    // audio_tracks array), not by the manifest's ffprobe `index` field.
    // Mediabunny's `track.id` is the container-level track ID (MP4 tkhd /
    // Matroska TrackNumber), which doesn't agree with ffprobe's `index` —
    // but the iteration order does, so we lean on that.
    const audioTracks = info.audio_tracks ?? []
    // Pre-flight each audio track for decode support. We have two paths:
    //   1. WebCodecs native (AAC, Opus, FLAC, MP3, …)
    //   2. Mediabunny custom-decoder registry (AC-3, E-AC-3 via vendored WASM)
    // So a track is "supported" if either path accepts it.
    const WASM_AUDIO_CODECS = new Set(["ac-3", "ec-3"])
    const audioSupport = await Promise.all(
        audioTracks.map(async (a) => {
            if (!a.codec_string || !a.sample_rate || !a.channels) return false
            if (WASM_AUDIO_CODECS.has(a.codec_string)) return true
            try {
                const { supported } = await AudioDecoder.isConfigSupported({
                    codec: a.codec_string,
                    sampleRate: a.sample_rate,
                    numberOfChannels: a.channels
                })
                return !!supported
            } catch {
                return false
            }
        })
    )
    const savedPrefs = getTrackPrefs(path)
    const initialAudioOrd = (() => {
        // A remembered, still-decodable choice wins over the heuristic.
        const savedAudio = savedPrefs?.audio
        if (Number.isInteger(savedAudio) && savedAudio >= 0 && savedAudio < audioTracks.length && audioSupport[savedAudio]) {
            return savedAudio
        }
        const isEng = (a) => {
            const lang = (a.language || "").toLowerCase()
            return lang === "en" || lang.startsWith("en-") || lang === "eng"
        }
        // Prefer an English track the browser can decode; then any supported
        // track; then English regardless; then track 0 as last resort.
        const enSupported = audioTracks.findIndex((a, i) => audioSupport[i] && isEng(a))
        if (enSupported >= 0) return enSupported
        const anySupported = audioSupport.findIndex(Boolean)
        if (anySupported >= 0) return anySupported
        const en = audioTracks.findIndex(isEng)
        if (en >= 0) return en
        return audioTracks.length > 0 ? 0 : -1
    })()
    const audioOptions =
        audioTracks.length > 1
            ? audioTracks.map((a, i) => {
                  const lang = a.language || `audio ${i + 1}`
                  const chInfo = a.channel_layout || (a.channels ? `${a.channels}ch` : null)
                  const ch = chInfo ? ` (${chInfo})` : ""
                  const codec = a.codec ? ` [${a.codec}]` : ""
                  const unsupp = audioSupport[i] ? "" : " — unsupported"
                  return { value: String(i), label: `${lang}${ch}${codec}${unsupp}` }
              })
            : []
    const noPlayableAudio = audioTracks.length > 0 && audioSupport.every((s) => !s)

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
    // Show the audio button whenever the file has audio (even if only one
    // track, so an "unsupported" status is still visible). The icon flips
    // to 🔇 when the current selection isn't decodable by this browser.
    const audioBtnLabel = () => {
        const initUnsupported = initialAudioOrd >= 0 && !audioSupport[initialAudioOrd]
        const icon = noPlayableAudio || initUnsupported ? "🔇" : "♪"
        if (audioOptions.length === 0) {
            const a = audioTracks[initialAudioOrd]
            const codec = a?.codec ? ` [${a.codec}]` : ""
            const suff = initUnsupported ? " — unsupported" : ""
            return `${icon} ${a?.language || "audio"}${codec}${suff}`
        }
        return `${icon} ` + labelFor(audioOptions, String(initialAudioOrd))
    }
    const audioBtn =
        audioTracks.length > 0 ? el("button", { className: "ctrl-audio", type: "button", title: "Audio" }, audioBtnLabel()) : null

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

    const stage = el("div", { className: "player-stage" }, host, cueOverlay, backBtn, controlBar)
    const wrap = el("div", { className: "player" }, stage, detailsBlock(info))
    app.replaceChildren(wrap)

    let currentAudio = initialAudioOrd
    let currentSubValue = ""
    void currentAudio
    void currentSubValue

    // Resume position from localStorage. The controller seeks here once
    // metadata is ready; attachPlayerControls below also wires the periodic
    // heartbeat that persists position back as playback advances.
    const startAt = (() => {
        const entry = getResume(path)
        return entry?.pos > 0 ? entry.pos : 0
    })()

    let controller
    try {
        const { startPlayer } = await import("/player.js")
        controller = await startPlayer({
            host,
            manifest: info,
            startAt,
            startAudioOrd: initialAudioOrd >= 0 ? initialAudioOrd : null,
            onError: (msg) => {
                app.replaceChildren(el("div", { className: "error" }, msg), detailsBlock(info))
            }
        })
        // Bridge: app.js's controls plumbing knows it as `video`; the
        // PlayerController exposes a compatible API + EventTarget surface.
        // Click-to-play needs a real DOM target since the controller isn't
        // in the DOM.
        host.addEventListener("click", () => {
            controller.paused ? controller.play() : controller.pause()
        })
        // Kick playback. play() no longer awaits the resume — Chrome's
        // autoplay policy can hang that promise indefinitely if no gesture
        // has happened. Whether playback actually starts depends on
        // audioCtx.state once the call returns; we check that just below.
        controller.play()
    } catch (e) {
        console.error("[player] startup failed", e)
        app.replaceChildren(el("div", { className: "error" }, "player failed to start: " + e.message), detailsBlock(info))
        return
    }
    const video = controller
    activeVideo = controller
    activePlay = { path, bingeId, video: controller }

    // Tap-to-play overlay. Chrome (and Safari, sometimes) gate
    // `AudioContext.resume()` behind a user gesture, so a deep link or a
    // hard-refresh during playback lands in the player with audioCtx
    // suspended. Without an overlay the page just shows a frozen first
    // frame and a play button hidden behind the auto-hiding OSD — easy to
    // miss. Show a big tap-target until the user interacts; remove on the
    // first `play` event (whether the gesture came from this overlay, the
    // ▶ button, spacebar, or the canvas click).
    if (controller.paused) {
        const tapOverlay = el(
            "button",
            { className: "tap-to-play", type: "button", "aria-label": "Play" },
            el("span", { className: "tap-to-play-icon" }, "▶")
        )
        tapOverlay.addEventListener("click", (ev) => {
            ev.stopPropagation()
            controller.play()
        })
        stage.appendChild(tapOverlay)
        controller.addEventListener("play", () => tapOverlay.remove(), { once: true })
    }

    // Subtitle rendering. We deliberately avoid the native <track> element:
    // tvOS UIWebView's VTT pipeline crashes on cue boundaries, and even on
    // desktop the native renderer ignores our stage-anchored .cue-overlay
    // positioning. Fetching + parsing in JS is the same code path everywhere.
    let cueGen = 0
    let activeCues = []
    let subsRafId = null

    // Parse VTT / SRT into [{start, end, text}]. Both formats share the
    // `HH:MM:SS.mmm --> HH:MM:SS.mmm` cue header line; SRT uses commas
    // instead of dots, which the comma→dot normalization handles.
    const parseVTT = (text) => {
        const parseTime = (s) => {
            const parts = s.replace(",", ".").split(":")
            if (parts.length === 2) return parseFloat(parts[0]) * 60 + parseFloat(parts[1])
            return parseFloat(parts[0]) * 3600 + parseFloat(parts[1]) * 60 + parseFloat(parts[2])
        }
        const cues = []
        for (const block of text.replace(/\r/g, "").split(/\n\n+/)) {
            const lines = block.split("\n")
            for (let i = 0; i < lines.length; i++) {
                const m = lines[i].match(/(\d[\d:.,]*)\s+-->\s+(\d[\d:.,]*)/)
                if (m) {
                    // Strip VTT inline markup (<i>, <v Speaker>, <00:00:01.000>
                    // timestamps, …) — we render as plain text via textContent.
                    const body = lines
                        .slice(i + 1)
                        .join("\n")
                        .replace(/<\/?[^>]+>/g, "")
                        .trim()
                    if (body) cues.push({ start: parseTime(m[1]), end: parseTime(m[2]), text: body })
                    break
                }
            }
        }
        return cues
    }

    // Parse ASS / SSA dialogue lines into [{start, end, text}]. ASS supports
    // styling (font, color, positioning), karaoke timing, etc., but we
    // deliberately downconvert to plain text — JASSUB or libass-via-WASM is
    // a future opt-in dependency. Strips `{\\tag}` codes and replaces `\N`
    // / `\n` with newlines.
    const parseASS = (text) => {
        const parseTime = (s) => {
            // ASS time format: H:MM:SS.cs (centiseconds, two-digit).
            const parts = s.trim().split(":")
            if (parts.length !== 3) return 0
            return parseFloat(parts[0]) * 3600 + parseFloat(parts[1]) * 60 + parseFloat(parts[2])
        }
        const lines = text.replace(/\r/g, "").split("\n")
        let format = null
        let inEvents = false
        const cues = []
        for (const raw of lines) {
            const line = raw.trim()
            if (line.startsWith("[")) {
                inEvents = line.toLowerCase() === "[events]"
                continue
            }
            if (!inEvents) continue
            if (line.toLowerCase().startsWith("format:")) {
                format = line
                    .slice(7)
                    .split(",")
                    .map((s) => s.trim().toLowerCase())
                continue
            }
            if (!line.toLowerCase().startsWith("dialogue:") || !format) continue
            // Dialogue: <Format-columns-comma-separated, with the last column
            // (Text) potentially containing commas itself>. Split on the first
            // N-1 commas and treat the remainder as the text field.
            const payload = line.slice(9)
            const cols = []
            let rest = payload
            for (let i = 0; i < format.length - 1; i++) {
                const c = rest.indexOf(",")
                if (c < 0) break
                cols.push(rest.slice(0, c).trim())
                rest = rest.slice(c + 1)
            }
            cols.push(rest)
            const get = (name) => cols[format.indexOf(name)]
            const start = parseTime(get("start") || "")
            const end = parseTime(get("end") || "")
            const body = (get("text") || "")
                .replace(/\{[^}]*\}/g, "") // override blocks {\\i1}, {\\pos(...)}, etc.
                .replace(/\\N/g, "\n")
                .replace(/\\n/g, "\n")
                .replace(/\\h/g, " ")
                .trim()
            if (body && end > start) cues.push({ start, end, text: body })
        }
        return cues
    }

    // SubViewer 1/2 format. Sometimes shipped with the wrong extension
    // (`.srt`) — common with old encoder pipelines (e.g. YIFY-era releases).
    // Header block at the top (`[INFORMATION]`, `[STYLE]`, …) followed by
    // cues whose times share one line, comma-separated:
    //     HH:MM:SS.cc,HH:MM:SS.cc
    //     <text lines until blank line>
    // `[br]` inside text is the SubViewer line break.
    const parseSubViewer = (text) => {
        const parseTime = (s) => {
            const parts = s.trim().split(":")
            if (parts.length !== 3) return NaN
            return parseFloat(parts[0]) * 3600 + parseFloat(parts[1]) * 60 + parseFloat(parts[2])
        }
        const cues = []
        const blocks = text.replace(/\r/g, "").split(/\n\n+/)
        for (const block of blocks) {
            const lines = block.split("\n")
            if (lines.length < 2) continue
            const m = lines[0].match(/^(\d{1,2}:\d{2}:\d{2}\.\d{1,3}),(\d{1,2}:\d{2}:\d{2}\.\d{1,3})\s*$/)
            if (!m) continue
            const start = parseTime(m[1])
            const end = parseTime(m[2])
            if (!isFinite(start) || !isFinite(end) || end <= start) continue
            const body = lines
                .slice(1)
                .join("\n")
                .replace(/\[br\]/gi, "\n")
                .trim()
            if (body) cues.push({ start, end, text: body })
        }
        return cues
    }

    // Pick a parser based on the declared format AND a quick content sniff —
    // files with the wrong extension are common (.srt that's actually
    // SubViewer, .vtt that's actually SRT, etc.).
    const parseSubtitle = (text, format) => {
        const head = text.slice(0, 256)
        if (/^\s*WEBVTT/i.test(head)) return parseVTT(text)
        if (/\[Script Info\]/i.test(head) || format === "ass" || format === "ssa") return parseASS(text)
        if (/\[INFORMATION\]|\[TITLE\]|\[SUBTITLE\]/i.test(head)) return parseSubViewer(text)
        // SubRip and "VTT without the header" both work through parseVTT.
        return parseVTT(text)
    }

    const renderSubs = () => {
        subsRafId = null
        if (!cueOverlay.isConnected) return
        if (!activeCues.length) {
            if (cueOverlay.textContent !== "") cueOverlay.textContent = ""
            return
        }
        // Small lookahead — currentTime lags wall-clock rendering slightly.
        const t = video.currentTime + 0.15
        let next = ""
        for (const c of activeCues) {
            if (t >= c.start && t <= c.end) {
                if (next) next += "\n"
                next += c.text
            }
        }
        if (cueOverlay.textContent !== next) cueOverlay.textContent = next
        subsRafId = requestAnimationFrame(renderSubs)
    }

    const kickSubsLoop = () => {
        if (subsRafId == null) subsRafId = requestAnimationFrame(renderSubs)
    }

    // Fetch a sidecar subtitle via /api/sidecar (raw bytes) and parse it
    // client-side. AbortController bounds the fetch so a stalled response
    // can't leave the picker in a "loading forever" state.
    const SUBS_FETCH_TIMEOUT_MS = 30000
    const applySubChoice = async (value) => {
        cueGen++
        const gen = cueGen
        currentSubValue = value
        // Remember the user's subtitle intent for next time (including "Off").
        setTrackPref(path, "sub", value)
        const label = value ? labelFor(subOptions, value) : "Off"
        subBtn.textContent = "CC " + label
        activeCues = []
        cueOverlay.textContent = ""
        if (!value) return
        const [kind, idxStr] = value.split(":")
        if (kind !== "sidecar") {
            console.warn(`[subs] unsupported track kind: ${kind}`)
            subBtn.textContent = "CC ⚠ " + label + " (unsupported)"
            currentSubValue = ""
            return
        }
        const sc = info.sidecars?.[parseInt(idxStr, 10)]
        if (!sc) {
            subBtn.textContent = "CC ⚠ " + label + " (missing)"
            currentSubValue = ""
            return
        }
        const ctrl = new AbortController()
        const timer = setTimeout(() => ctrl.abort(), SUBS_FETCH_TIMEOUT_MS)
        console.log(`[subs] fetching ${sc.url} (${label}, format=${sc.format})`)
        try {
            const r = await fetch(sc.url, { signal: ctrl.signal })
            if (gen !== cueGen) return
            if (!r.ok) {
                console.error(`[subs] fetch failed: ${r.status} ${r.statusText} for ${value}`)
                subBtn.textContent = "CC ⚠ " + label
                currentSubValue = ""
                return
            }
            const text = await r.text()
            if (gen !== cueGen) return
            activeCues = parseSubtitle(text, sc.format)
            console.log(`[subs] loaded ${activeCues.length} cues for ${value}`)
            if (activeCues.length === 0) {
                subBtn.textContent = "CC ⚠ " + label + " (empty)"
            }
            kickSubsLoop()
        } catch (e) {
            if (gen !== cueGen) return
            const aborted = e.name === "AbortError"
            console.error(
                `[subs] ${aborted ? "timed out after " + SUBS_FETCH_TIMEOUT_MS + "ms" : "fetch error"} for ${value}:`,
                e
            )
            subBtn.textContent = "CC ⚠ " + label + (aborted ? " (timeout)" : " (error)")
            currentSubValue = ""
        } finally {
            clearTimeout(timer)
        }
    }

    // Apply an audio choice: the player swaps the audio decoder + sink +
    // pump to the new track without disturbing video playback. Track ids
    // are the source stream indices (ffprobe `index` == mediabunny track
    // `.id`).
    const applyAudioChoice = async (value) => {
        const audioIdx = parseInt(value, 10)
        if (audioIdx === currentAudio) return
        const prev = currentAudio
        currentAudio = audioIdx
        if (audioBtn) audioBtn.textContent = "♪ " + labelFor(audioOptions, value)
        console.log(`[audio] switching ${prev} -> ${audioIdx}`)
        try {
            await controller.switchAudio(audioIdx)
            setTrackPref(path, "audio", audioIdx)
        } catch (e) {
            console.warn("[audio] switch failed", e)
            // Revert label so the picker reflects reality.
            currentAudio = prev
            if (audioBtn) audioBtn.textContent = "♪ " + labelFor(audioOptions, String(prev))
        }
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
        // Up=subs, Down=audio is the contract everywhere. If there are no
        // alternative audio tracks we deliberately do nothing here rather
        // than fall through to the subs picker — the previous fallthrough
        // meant Up and Down opened the same dialog on most files and felt
        // inconsistent across the library.
        if (audioOptions.length === 0) {
            console.log("[player] Down ignored — only one audio track")
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

    // Restore the remembered subtitle choice (audio is applied at boot via
    // startAudioOrd above). Only if the saved value still maps to a real
    // option for this file; "" (Off) is the default so we skip it.
    if (savedPrefs?.sub && subOptions.some((o) => o.value === savedPrefs.sub)) {
        applySubChoice(savedPrefs.sub)
    }

    video.volume = initVolume
    video.muted = savedMuted
    attachPlayerControls({ video, stage, playBtn, scrub, timeDisplay, muteBtn, volumeSlider, fsBtn, path, bingeId })
    // Desktop keyboard shortcuts: Space/Enter play-pause, ←/→ seek, Esc back.
    // Mouse / hover / wheel still work because the controls are real elements
    // with their own click handlers.
    installPlayerKeyHandler({ video, stage })
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
async function maybeShowContinueNext({ stage, path, bingeId }) {
    if (!path) return
    let nextVpath, nextName, nextHref
    if (bingeId) {
        // The just-finished video was already popped in the `ended` handler,
        // so the queue's new front IS what plays next. Keep the binge binding.
        const front = bingeById(bingeId)?.vpaths?.[0]
        if (!front) return
        nextVpath = front
        nextName = displayName(front.split("/").pop() || front)
        nextHref = "#/play/" + encodePath(front) + "?binge=" + encodeURIComponent(bingeId)
    } else {
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
        nextVpath = data.vpath
        nextName = data.name
        nextHref = "#/play/" + encodePath(data.vpath)
    }
    // Already showing one? Replace it (avoid stacking on re-end).
    const old = stage.querySelector(".continue-next")
    if (old) old.remove()

    const btn = el(
        "a",
        { className: "continue-next-btn", href: nextHref },
        el("div", { className: "continue-next-arrow" }, "▶"),
        el(
            "div",
            { className: "continue-next-meta" },
            el("div", { className: "continue-next-label" }, "Continue"),
            el("div", { className: "continue-next-name" }, nextName)
        )
    )
    const overlay = el("div", { className: "continue-next" }, btn)
    stage.append(overlay)
    // Focus the anchor so Enter activates it natively and it's the obvious
    // target on screen.
    btn.focus()
    console.log(`[next] showing Continue → ${nextVpath}`)
}

function attachPlayerControls({ video, stage, playBtn, scrub, timeDisplay, muteBtn, volumeSlider, fsBtn, path, bingeId }) {
    let scrubbing = false
    // Resume-position restore happens in startPlayer({ startAt }) — the
    // WebCodecs player needs the start time at boot, not as a post-load seek,
    // so the pumps + decoder seed once at the right keyframe instead of
    // racing a near-immediate second seek.

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
        // Natural end ⇒ finished ⇒ advance the bound binge before we ask what's
        // next, so the Continue button reflects the popped queue.
        if (bingeId) maybeAdvanceBinge({ bingeId, path, finished: true, video })
        await maybeShowContinueNext({ stage, path, bingeId })
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

    // The WebCodecs player dispatches `loadedmetadata`/`durationchange` from
    // within `startPlayer` — i.e. before attachPlayerControls runs and can
    // register listeners. Set scrub.max synchronously here too so we don't
    // miss the initial state and end up with scrub.max stuck at the input's
    // default of "100".
    const syncScrubMax = () => {
        if (isFinite(video.duration) && video.duration > 0) scrub.max = String(video.duration)
    }
    video.addEventListener("loadedmetadata", syncScrubMax)
    video.addEventListener("durationchange", syncScrubMax)
    syncScrubMax()
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
    // Space/Enter/arrow/Esc shortcuts live in installPlayerKeyHandler
    // (window.duplexPlayer), dispatched from the global capture keydown.

    // OSD auto-hide: a fixed dwell after the last input or paint, then dim.
    // Mouse moves / hover / pause / key presses all re-surface via
    // showControls.
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
    return el("details", null, el("summary", null, info.path || "(no path)"), el("pre", null, JSON.stringify(info, null, 2)))
}

function render() {
    const r = parseRoute()
    // Always tear down any picker and the previous player before swapping
    // routes — teardownPlayer also nulls window.duplexPlayer so leftover
    // key handlers don't keep firing in the next view.
    closeOpenPicker()
    // Playing a binge's next-up video from outside the binge (library, recent,
    // search, Continue Watching) routes through the chooser first, unless an
    // explicit binge binding ("?binge=<id>" or "?binge=none") is already set.
    const isChooser = r.kind === "play" && !r.bingeId && bingesWithFront(r.path).length > 0
    if (r.kind !== "play" || isChooser) teardownPlayer()
    if (r.kind === "play") {
        if (isChooser) renderBingeChooser(r.path)
        else renderPlay(r.path, r.bingeId === "none" ? null : r.bingeId)
    } else if (r.kind === "settings") renderSettings()
    else if (r.kind === "search") renderSearch(r.query)
    else renderBrowse(r.path)
    syncSearchBox()
}

// Find the nearest ancestor that actually scrolls vertically. Walks up until
// it hits one with `overflow-y: auto|scroll` and a scrollable amount of
// content; falls back to null (caller should treat as "no scroller").
function scrollableAncestor(el) {
    let p = el.parentElement
    while (p) {
        const s = getComputedStyle(p)
        const oy = s.overflowY
        if ((oy === "auto" || oy === "scroll") && p.scrollHeight > p.clientHeight) {
            return p
        }
        p = p.parentElement
    }
    return null
}

// Scroll `el` into view, centering it vertically when it isn't already fully
// visible. Skips the scroll entirely when the element fits inside the
// scroller's viewport — so incremental arrow-nav within the visible area
// doesn't constantly re-center and feel jittery.
function scrollSelectionIntoView(el) {
    if (!el) return
    const scroller = scrollableAncestor(el)
    if (!scroller) {
        el.scrollIntoView({ block: "nearest", inline: "nearest" })
        return
    }
    const er = el.getBoundingClientRect()
    const sr = scroller.getBoundingClientRect()
    if (er.top >= sr.top && er.bottom <= sr.bottom) return
    el.scrollIntoView({ block: "center", inline: "nearest" })
}

// Modal list picker for subtitle / audio track choice. Stays open until the
// user picks an item or hits Escape; keyboard nav (↑/↓/Enter/Esc) works
// inside the modal, and clicking an item selects it. While open it swallows
// all relevant keys so the player doesn't also react.
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
        if (selEl) scrollSelectionIntoView(selEl)
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

document.addEventListener(
    "keydown",
    (ev) => {
        // Priority 1: a modal picker is open — it owns ↑/↓/Enter/Esc until the
        // user picks or cancels.
        if (window.duplexPicker) {
            if (window.duplexPicker.handleKey(ev)) {
                ev.preventDefault()
                ev.stopImmediatePropagation()
            }
            return
        }
        // Priority 2: the player owns its keys (play/pause, seek, back).
        if (window.duplexPlayer?.handleKey?.(ev)) {
            ev.stopImmediatePropagation()
            return
        }
        // Priority 3: browse / search / settings. Escape backs out — but when
        // the search box is focused it just blurs (and clears) instead.
        if (ev.key === "Escape") {
            const active = document.activeElement
            if (active && active.id === "search-box") {
                ev.preventDefault()
                active.value = ""
                active.blur()
                if (parseRoute().kind === "search") location.hash = "#/browse/"
                return
            }
            ev.preventDefault()
            if (history.length > 1) history.back()
            else location.hash = "#/browse/"
        }
    },
    true
)

window.addEventListener("hashchange", render)
window.addEventListener("DOMContentLoaded", () => {
    wireSearchBox()
    if (!location.hash) location.hash = "#/browse/"
    render()
})
