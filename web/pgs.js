// PGS (Presentation Graphic Stream) subtitle decoder + canvas overlay.
//
// PGS is what BluRay remuxes carry for image subtitles (CodecID S_HDMV/PGS).
// libVLC decodes these natively on tvOS; the browser has no such luxury, so we
// decode them here: parse the segment stream of each display set, RLE-decode
// the object bitmaps, apply the palette, and composite the result onto an
// overlay canvas sized to the subtitle's native resolution (1920×1080 for
// Evangelion), which CSS then scales to sit exactly over the player canvas.
//
// `PgsSession` is the pure decoder (no DOM — unit-testable in node).
// `PgsOverlay` wraps a <canvas> and drives presentation against the playhead.

// Segment type bytes within a display set.
const SEG_PDS = 0x14 // Palette Definition
const SEG_ODS = 0x15 // Object Definition
const SEG_PCS = 0x16 // Presentation Composition
const SEG_WDS = 0x17 // Window Definition
const SEG_END = 0x80 // End of display set

// Composition states (PCS).
const STATE_EPOCH_START = 0x80

// Convert a YCbCr+alpha palette entry to RGBA. PGS stores Y, Cr, Cb, alpha (Cr
// before Cb). HD content (height ≥ 720) is BT.709; SD is BT.601. For typical
// white-text/black-outline subtitles chroma sits near neutral, so the matrix
// choice barely matters, but we pick the correct one anyway.
function ycbcrToRgb(y, cr, cb, hd) {
    const c = y - 16
    const d = cb - 128
    const e = cr - 128
    let r, g, b
    if (hd) {
        r = 1.1644 * c + 1.7927 * e
        g = 1.1644 * c - 0.2132 * d - 0.5329 * e
        b = 1.1644 * c + 2.1124 * d
    } else {
        r = 1.1644 * c + 1.596 * e
        g = 1.1644 * c - 0.3917 * d - 0.813 * e
        b = 1.1644 * c + 2.0172 * d
    }
    return [clamp8(r), clamp8(g), clamp8(b)]
}

function clamp8(v) {
    return v < 0 ? 0 : v > 255 ? 255 : v | 0
}

// Decode a PGS-RLE object into an RGBA buffer using `palette` (a 1024-byte
// table of 256 RGBA entries). Color index 0 is conventionally transparent.
function decodeRle(rle, width, height, palette) {
    const out = new Uint8ClampedArray(width * height * 4)
    let i = 0
    let x = 0
    let y = 0
    while (i < rle.length && y < height) {
        let color
        let run
        let b = rle[i++]
        if (b !== 0) {
            color = b
            run = 1
        } else {
            b = rle[i++]
            if (b === 0) {
                // End of line.
                x = 0
                y++
                continue
            }
            const cnt = b & 0x3f
            if (b & 0x40) run = (cnt << 8) | rle[i++]
            else run = cnt
            color = b & 0x80 ? rle[i++] : 0
        }
        const po = color * 4
        const pr = palette[po]
        const pg = palette[po + 1]
        const pb = palette[po + 2]
        const pa = palette[po + 3]
        for (let k = 0; k < run && x < width; k++, x++) {
            const idx = (y * width + x) * 4
            out[idx] = pr
            out[idx + 1] = pg
            out[idx + 2] = pb
            out[idx + 3] = pa
        }
    }
    return out
}

export class PgsSession {
    constructor() {
        this.reset()
    }

    reset() {
        this.palettes = new Map() // paletteId → Uint8ClampedArray(1024)
        this.objects = new Map() // objectId → { width, height, rle:Uint8Array }
        this.windows = new Map() // windowId → { x, y, w, h }
        this._odsAccum = new Map() // objectId → { width, height, chunks:[] }
        this.hd = true
    }

    // Decode one display set (a single MKV block payload: PCS … END). Returns
    // { clear, regions, width, height } or null when no PCS was present.
    // `regions` is [{ x, y, width, height, rgba }].
    decodeDisplaySet(payload) {
        let p = 0
        let comp = null
        while (p + 3 <= payload.length) {
            const type = payload[p]
            const size = (payload[p + 1] << 8) | payload[p + 2]
            const seg = payload.subarray(p + 3, p + 3 + size)
            p += 3 + size
            switch (type) {
                case SEG_PCS:
                    comp = this._parsePCS(seg)
                    break
                case SEG_WDS:
                    this._parseWDS(seg)
                    break
                case SEG_PDS:
                    this._parsePDS(seg)
                    break
                case SEG_ODS:
                    this._parseODS(seg)
                    break
                case SEG_END:
                    break
            }
        }
        if (!comp) return null
        if (comp.objects.length === 0) return { clear: true, regions: [], width: comp.width, height: comp.height }

        const palette = this.palettes.get(comp.paletteId)
        const regions = []
        for (const co of comp.objects) {
            const obj = this.objects.get(co.objectId)
            if (!obj || !palette) continue
            const rgba = decodeRle(obj.rle, obj.width, obj.height, palette)
            regions.push({ x: co.x, y: co.y, width: obj.width, height: obj.height, rgba })
        }
        return { clear: regions.length === 0, regions, width: comp.width, height: comp.height }
    }

    _parsePCS(seg) {
        const width = (seg[0] << 8) | seg[1]
        const height = (seg[2] << 8) | seg[3]
        this.hd = height >= 720
        // seg[4] frame rate, seg[5..6] composition number.
        const state = seg[7]
        if (state === STATE_EPOCH_START) {
            // A new epoch resends everything — drop stale palettes/objects so a
            // post-seek decode never references something we never saw.
            this.palettes.clear()
            this.objects.clear()
            this.windows.clear()
            this._odsAccum.clear()
        }
        // seg[8] palette update flag.
        const paletteId = seg[9]
        const numObjects = seg[10]
        const objects = []
        let o = 11
        for (let n = 0; n < numObjects; n++) {
            const objectId = (seg[o] << 8) | seg[o + 1]
            const windowId = seg[o + 2]
            const croppedFlag = seg[o + 3]
            const x = (seg[o + 4] << 8) | seg[o + 5]
            const y = (seg[o + 6] << 8) | seg[o + 7]
            o += 8
            if (croppedFlag & 0x80) o += 8 // skip crop rect
            objects.push({ objectId, windowId, x, y })
        }
        return { width, height, paletteId, objects }
    }

    _parseWDS(seg) {
        const count = seg[0]
        let o = 1
        for (let n = 0; n < count; n++) {
            const id = seg[o]
            const x = (seg[o + 1] << 8) | seg[o + 2]
            const y = (seg[o + 3] << 8) | seg[o + 4]
            const w = (seg[o + 5] << 8) | seg[o + 6]
            const h = (seg[o + 7] << 8) | seg[o + 8]
            this.windows.set(id, { x, y, w, h })
            o += 9
        }
    }

    _parsePDS(seg) {
        const paletteId = seg[0]
        // seg[1] palette version.
        let pal = this.palettes.get(paletteId)
        if (!pal) {
            pal = new Uint8ClampedArray(256 * 4)
            this.palettes.set(paletteId, pal)
        }
        // Body after the 2-byte header is a run of 5-byte entries.
        for (let i = 2; i + 5 <= seg.length; i += 5) {
            const entry = seg[i]
            const y = seg[i + 1]
            const cr = seg[i + 2]
            const cb = seg[i + 3]
            const a = seg[i + 4]
            const [r, g, b] = ycbcrToRgb(y, cr, cb, this.hd)
            const po = entry * 4
            pal[po] = r
            pal[po + 1] = g
            pal[po + 2] = b
            pal[po + 3] = a
        }
    }

    _parseODS(seg) {
        const objectId = (seg[0] << 8) | seg[1]
        // seg[2] version.
        const seqFlag = seg[3]
        if (seqFlag & 0x80) {
            // First-in-sequence: carries object_data_length + width + height.
            const width = (seg[7] << 8) | seg[8]
            const height = (seg[9] << 8) | seg[10]
            this._odsAccum.set(objectId, { width, height, chunks: [seg.subarray(11)] })
        } else {
            const acc = this._odsAccum.get(objectId)
            if (acc) acc.chunks.push(seg.subarray(4))
        }
        if (seqFlag & 0x40) {
            // Last-in-sequence: concatenate and store the finished object.
            const acc = this._odsAccum.get(objectId)
            if (acc) {
                this.objects.set(objectId, { width: acc.width, height: acc.height, rle: concat(acc.chunks) })
                this._odsAccum.delete(objectId)
            }
        }
    }
}

function concat(chunks) {
    if (chunks.length === 1) return chunks[0]
    let total = 0
    for (const c of chunks) total += c.length
    const out = new Uint8Array(total)
    let o = 0
    for (const c of chunks) {
        out.set(c, o)
        o += c.length
    }
    return out
}

// Browser-side presentation: holds decoded display sets keyed by start time and
// paints the active one onto `canvas` (sized to the PGS native resolution).
// Pruned as the playhead advances so memory stays bounded.
export class PgsOverlay {
    constructor(canvas) {
        this.canvas = canvas
        this.ctx = canvas.getContext("2d")
        this.session = new PgsSession()
        this.sets = [] // [{ startMs, clear, regions }]
        this._lastDrawn = undefined
    }

    reset() {
        this.session.reset()
        this.sets = []
        this._lastDrawn = undefined
        this._clear()
    }

    // Feed a raw (already-inflated) PGS block at absolute `startMs`.
    addBlock(startMs, payload) {
        let ds
        try {
            ds = this.session.decodeDisplaySet(payload)
        } catch (e) {
            console.warn("[pgs] decode failed", e)
            return
        }
        if (!ds) return
        if (ds.width && (this.canvas.width !== ds.width || this.canvas.height !== ds.height)) {
            this.canvas.width = ds.width
            this.canvas.height = ds.height
            this._lastDrawn = undefined
        }
        this.sets.push({ startMs, clear: ds.clear, regions: ds.regions })
        // Keep the list time-ordered; blocks arrive in order but a seek can
        // splice an earlier range back in.
        if (this.sets.length > 1 && startMs < this.sets[this.sets.length - 2].startMs) {
            this.sets.sort((a, b) => a.startMs - b.startMs)
        }
    }

    // Paint whatever display set is active at `currentMs`. Cheap to call every
    // rAF: it only touches the canvas when the active set changes.
    render(currentMs) {
        let active = null
        for (const s of this.sets) {
            if (s.startMs <= currentMs + 1) active = s
            else break
        }
        // Drop sets well behind the playhead so the RGBA buffers don't pile up.
        if (this.sets.length > 32) {
            const cutoff = currentMs - 20000
            const keep = this.sets.filter((s) => s.startMs >= cutoff || s === active)
            if (keep.length !== this.sets.length) this.sets = keep
        }
        if (active === this._lastDrawn) return
        this._lastDrawn = active
        this._clear()
        if (!active || active.clear) return
        for (const r of active.regions) {
            if (!r.width || !r.height) continue
            this.ctx.putImageData(new ImageData(r.rgba, r.width, r.height), r.x, r.y)
        }
    }

    _clear() {
        if (this.ctx) this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height)
    }
}
