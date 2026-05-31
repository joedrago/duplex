// Embedded-subtitle controller: renders subtitle tracks that live *inside* the
// MKV container (which Mediabunny refuses to surface). Two renderers, one
// playhead-following extractor:
//
//   - PGS (image subs): decoded by pgs.js and composited onto an overlay canvas.
//   - ASS (styled text): handed to JASSUB (libass-in-WASM) with the embedded
//     fonts extracted from the file, so the "fancy" fansub styling renders the
//     way it does under VLC on tvOS.
//
// The extractor (`mkv-subs.js`) can't cheaply grab the whole subtitle track up
// front (the blocks are scattered across a multi-GB file), so we follow the
// playhead: read the clusters around the current time, feed their blocks to the
// active renderer, and re-seek when the user jumps. On localhost the bytes are
// already cached from the player's own read, so the extra reads are cheap.

import { openMkvSubtitles } from "/mkv-subs.js"
import { PgsOverlay } from "/pgs.js"
import JASSUB from "/vendor/jassub/jassub.mjs"

const JASSUB_WORKER_URL = "/vendor/jassub/jassub-worker.js"
const JASSUB_WASM_URL = "/vendor/jassub/jassub-worker.wasm"
const JASSUB_MODERN_WASM_URL = "/vendor/jassub/jassub-worker-modern.wasm"
const JASSUB_DEFAULT_FONT_URL = "/vendor/jassub/default.woff2"

// How far ahead of the playhead to keep extracting, the polling cadence, and
// how far behind the covered range the playhead may drift before we treat it as
// a backward seek and re-read.
const LOOKAHEAD_SEC = 12
const DRIVER_TICK_MS = 350
// Playhead delta between driver ticks above which we treat the move as a seek
// (normal playback, even at 4×, advances well under this per tick).
const JUMP_THRESHOLD_SEC = 5

// Subtitle kinds this controller knows how to render.
const RENDERABLE = new Set(["pgs", "ass"])

// ---- small helpers ---------------------------------------------------------

function makeOverlayCanvas(stage, className) {
    const c = document.createElement("canvas")
    c.className = className
    stage.appendChild(c)
    return c
}

function pad2(n) {
    return n < 10 ? "0" + n : "" + n
}

// Format milliseconds as an ASS timestamp: H:MM:SS.cc (centiseconds).
function fmtAssTime(ms) {
    if (!isFinite(ms) || ms < 0) ms = 0
    const cs = Math.round(ms / 10)
    const h = Math.floor(cs / 360000)
    const m = Math.floor((cs % 360000) / 6000)
    const s = Math.floor((cs % 6000) / 100)
    const c = cs % 100
    return `${h}:${pad2(m)}:${pad2(s)}.${pad2(c)}`
}

// Split `str` on the first `n` commas, returning n+1 fields (the last keeps any
// remaining commas — ASS Text routinely contains them).
function splitFields(str, n) {
    const out = []
    let start = 0
    for (let i = 0; i < n; i++) {
        const c = str.indexOf(",", start)
        if (c < 0) {
            out.push(str.slice(start))
            return out
        }
        out.push(str.slice(start, c))
        start = c + 1
    }
    out.push(str.slice(start))
    return out
}

// ---- font name-table parsing ----------------------------------------------

// Pull the family-ish names out of a TrueType/OpenType font's `name` table so
// we can register it under the names libass will request. Returns lowercased
// names (Font Family / Full Name / Typographic Family); empty if the bytes
// aren't a parseable sfnt (woff/woff2/collections fall back to the filename).
function fontFamilies(bytes) {
    try {
        const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
        const tag = dv.getUint32(0)
        // 0x00010000 (TrueType), 'true', 'OTTO'. Skip 'ttcf'/'wOFF'/'wOF2'.
        if (tag !== 0x00010000 && tag !== 0x74727565 && tag !== 0x4f54544f) return []
        const numTables = dv.getUint16(4)
        let nameOff = 0
        for (let i = 0; i < numTables; i++) {
            const rec = 12 + i * 16
            if (dv.getUint32(rec) === 0x6e616d65 /* 'name' */) {
                nameOff = dv.getUint32(rec + 8)
                break
            }
        }
        if (!nameOff) return []
        const count = dv.getUint16(nameOff + 2)
        const strOff = nameOff + dv.getUint16(nameOff + 4)
        const names = new Set()
        for (let i = 0; i < count; i++) {
            const rec = nameOff + 6 + i * 12
            const platformId = dv.getUint16(rec)
            const nameId = dv.getUint16(rec + 6)
            if (nameId !== 1 && nameId !== 4 && nameId !== 16) continue
            const len = dv.getUint16(rec + 8)
            const off = strOff + dv.getUint16(rec + 10)
            let s
            if (platformId === 1) {
                // Mac Roman — ASCII-ish.
                s = ""
                for (let j = 0; j < len; j++) s += String.fromCharCode(bytes[off + j])
            } else {
                // Windows/Unicode — UTF-16BE.
                s = ""
                for (let j = 0; j + 1 < len; j += 2) s += String.fromCharCode((bytes[off + j] << 8) | bytes[off + j + 1])
            }
            s = s.trim().toLowerCase()
            if (s) names.add(s)
        }
        return [...names]
    } catch {
        return []
    }
}

// ---- public controller -----------------------------------------------------

export class EmbeddedSubtitles {
    constructor({ rawUrl, stage, videoWidth, videoHeight, getTimeSec, isPaused }) {
        this.rawUrl = rawUrl
        this.stage = stage
        this.videoWidth = videoWidth || 1920
        this.videoHeight = videoHeight || 1080
        this.getTimeSec = getTimeSec
        this.isPaused = isPaused || (() => false)

        this.mkv = null
        this.tracks = [] // picker options: [{ value, label, kind, number }]

        // Active selection + its renderer + the playhead driver.
        this._active = null
        this._sink = null
        this._driverTimer = null
        this._rafId = null
        this._coveredToSec = -Infinity
        // Playhead position observed on the previous driver tick, for jump
        // (seek) detection — a big delta in either direction means re-seek.
        this._lastTickTime = -Infinity
        // Bumped on every select/disable so an in-flight async setup or driver
        // tick can detect it's been superseded and bail.
        this._gen = 0
    }

    // Parse the MKV header and return the renderable subtitle tracks as picker
    // options. Returns [] for non-MKV files (MP4 etc.) so callers can no-op.
    async init() {
        try {
            this.mkv = await openMkvSubtitles(this.rawUrl)
        } catch (e) {
            console.warn("[embsubs] open failed:", e)
            this.mkv = null
        }
        if (!this.mkv) return []
        this.tracks = this.mkv
            .subtitleTracks()
            .filter((t) => RENDERABLE.has(t.kind))
            .map((t) => ({
                value: `embed:${t.number}`,
                label: this._label(t),
                kind: t.kind,
                number: t.number
            }))
        console.log(
            `[embsubs] ${this.tracks.length} embedded subtitle track(s):`,
            this.tracks.map((t) => t.label)
        )
        return this.tracks
    }

    _label(t) {
        const tag = t.kind === "pgs" ? "PGS" : "ASS"
        const base = t.name || t.language || "Subtitle"
        return `${base} (${tag})`
    }

    // Select an embedded track by its picker value ("embed:<trackNumber>").
    async select(value) {
        this.disable()
        const gen = this._gen
        const num = parseInt(value.split(":")[1], 10)
        const track = this.mkv?.tracks.find((t) => t.number === num)
        if (!track) return
        this._active = track
        try {
            if (track.kind === "pgs") this._sink = this._makePgsSink()
            else if (track.kind === "ass") this._sink = await this._makeAssSink(track)
        } catch (e) {
            console.warn("[embsubs] renderer setup failed:", e)
            this._active = null
            return
        }
        if (gen !== this._gen || !this._sink) return // superseded while awaiting
        this._coveredToSec = -Infinity
        this._lastTickTime = -Infinity
        this._tick()
        this._renderLoop()
        console.log(`[embsubs] selected #${track.number} (${track.kind})`)
    }

    // Stop and tear down whatever is currently rendering. Safe to call when
    // nothing is active.
    disable() {
        this._gen++
        this._active = null
        if (this._driverTimer) {
            clearTimeout(this._driverTimer)
            this._driverTimer = null
        }
        if (this._rafId != null) {
            cancelAnimationFrame(this._rafId)
            this._rafId = null
        }
        if (this._sink) {
            try {
                this._sink.dispose()
            } catch (e) {
                console.warn("[embsubs] sink dispose threw:", e)
            }
            this._sink = null
        }
    }

    dispose() {
        this.disable()
        this.mkv = null
    }

    // ---- renderers ---------------------------------------------------------

    _makePgsSink() {
        const canvas = makeOverlayCanvas(this.stage, "sub-overlay pgs-overlay")
        const overlay = new PgsOverlay(canvas)
        return {
            addBlock: (b) => overlay.addBlock(b.startMs, b.payload),
            render: (tSec) => overlay.render(tSec * 1000),
            dispose: () => {
                overlay.reset()
                canvas.remove()
            }
        }
    }

    async _makeAssSink(track) {
        const header = new TextDecoder().decode(track.codecPrivate || new Uint8Array())
        const availableFonts = await this._buildAvailableFonts()
        const canvas = makeOverlayCanvas(this.stage, "sub-overlay ass-overlay")

        const jassub = new JASSUB({
            canvas,
            workerUrl: JASSUB_WORKER_URL,
            wasmUrl: JASSUB_WASM_URL,
            modernWasmUrl: JASSUB_MODERN_WASM_URL,
            availableFonts,
            fallbackFont: "liberation sans",
            // Manual, timer-based rendering: there's no <video> element to hang
            // requestVideoFrameCallback off, so we feed time via setCurrentTime.
            onDemandRender: false,
            subContent: header + "\n"
        })
        // Render the subtitle plane at the video's native resolution; CSS
        // letterboxes the canvas to sit exactly over the picture.
        jassub.resize(this.videoWidth, this.videoHeight)

        // Events arrive incrementally as the playhead advances. We accumulate
        // them keyed by ReadOrder (so re-reads after a seek dedupe) and rebuild
        // the full ASS document on a short debounce — robust against libass
        // event-field quirks, and a few-hundred-line rebuild is cheap.
        const events = new Map()
        let dirty = false
        let rebuildTimer = null
        const rebuild = () => {
            rebuildTimer = null
            if (!dirty) return
            dirty = false
            const lines = [...events.values()].join("\n")
            jassub.setTrack(header + "\n" + lines + "\n")
        }
        const scheduleRebuild = () => {
            if (rebuildTimer == null) rebuildTimer = setTimeout(rebuild, 200)
        }

        let lastTimeSent = -1
        return {
            addBlock: (b) => {
                const line = this._assDialogue(b)
                if (!line) return
                if (!events.has(line.key)) {
                    events.set(line.key, line.text)
                    dirty = true
                    scheduleRebuild()
                }
            },
            render: (tSec) => {
                // Throttle the time messages — libass renders on its own timer;
                // it just needs the current position kept fresh.
                if (Math.abs(tSec - lastTimeSent) < 0.05) return
                lastTimeSent = tSec
                jassub.setCurrentTime(this.isPaused(), tSec)
            },
            dispose: () => {
                if (rebuildTimer) clearTimeout(rebuildTimer)
                try {
                    jassub.destroy()
                } catch (e) {
                    console.warn("[embsubs] jassub destroy threw:", e)
                }
                canvas.remove()
            }
        }
    }

    // Reconstruct a Dialogue line from an MKV ASS block. The block payload is
    // the event minus its timing: ReadOrder,Layer,Style,Name,MarginL,MarginR,
    // MarginV,Effect,Text — Start/End come from the block timestamp+duration.
    _assDialogue(b) {
        const text = new TextDecoder().decode(b.payload)
        const f = splitFields(text, 8) // 8 commas → 9 fields
        if (f.length < 9) return null
        const [readOrder, layer, style, name, ml, mr, mv, effect, body] = f
        const start = fmtAssTime(b.startMs)
        const end = fmtAssTime(b.startMs + (b.durationMs || 0))
        const line = `Dialogue: ${layer},${start},${end},${style},${name},${ml},${mr},${mv},${effect},${body}`
        return { key: readOrder + "|" + start, text: line }
    }

    // Build JASSUB's availableFonts map from the embedded attachments. Values
    // are the raw font bytes (JASSUB loads them lazily, only when libass asks
    // for that family), keyed by every name a font advertises plus its filename
    // stem as a fallback. Always includes the bundled fallback.
    async _buildAvailableFonts() {
        const fonts = { "liberation sans": JASSUB_DEFAULT_FONT_URL }
        let attachments = []
        try {
            attachments = await this.mkv.getAttachments()
        } catch (e) {
            console.warn("[embsubs] attachment read failed:", e)
        }
        let count = 0
        for (const a of attachments) {
            const mime = (a.mime || "").toLowerCase()
            const name = (a.filename || "").toLowerCase()
            const looksFont = mime.includes("font") || /\.(ttf|otf|ttc|woff2?|eot)$/.test(name)
            if (!looksFont) continue
            const keys = fontFamilies(a.data)
            if (keys.length === 0 && name) keys.push(name.replace(/\.[^.]+$/, ""))
            for (const k of keys) if (k && !fonts[k]) fonts[k] = a.data
            count++
        }
        console.log(`[embsubs] registered ${count} embedded font(s)`)
        return fonts
    }

    // ---- playhead-following driver -----------------------------------------

    _tick = () => {
        const gen = this._gen
        ;(async () => {
            if (gen !== this._gen || !this._active || !this._sink) return
            const t = this.getTimeSec()
            // A large jump since the last tick is a seek (forward or backward) —
            // even normal 4× playback only advances ~1.4s per tick. Reposition
            // the reader and re-read from here so a backward seek repopulates
            // display sets the renderer may have pruned.
            if (Math.abs(t - this._lastTickTime) > JUMP_THRESHOLD_SEC) {
                this.mkv.seek(Math.max(0, t - 1))
                this._coveredToSec = Math.max(0, t - 1)
            }
            this._lastTickTime = t
            // Read forward until we're buffered LOOKAHEAD ahead, bounded so one
            // tick never hogs the main thread on a long catch-up.
            let budget = 60
            while (this._coveredToSec < t + LOOKAHEAD_SEC && budget-- > 0) {
                const c = await this.mkv.nextCluster(this._active.number)
                if (gen !== this._gen) return
                if (!c) {
                    this._coveredToSec = Infinity // end of file
                    break
                }
                for (const b of c.blocks) this._sink.addBlock(b)
                this._coveredToSec = c.clusterTimeSec
            }
            if (gen !== this._gen) return
            this._driverTimer = setTimeout(this._tick, DRIVER_TICK_MS)
        })().catch((e) => {
            if (gen === this._gen) console.warn("[embsubs] driver tick threw:", e)
        })
    }

    _renderLoop = () => {
        if (!this._active || !this._sink) return
        try {
            this._sink.render(this.getTimeSec())
        } catch (e) {
            console.warn("[embsubs] render threw:", e)
        }
        this._rafId = requestAnimationFrame(this._renderLoop)
    }
}
