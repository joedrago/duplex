// Streaming Matroska subtitle reader.
//
// Mediabunny demuxes the video/audio for the player but drops every subtitle
// track from MKV files: it never assigns `info` for TrackType 17, and it
// refuses the PGS tracks outright ("unsupported content encoding" — they're
// zlib-compressed). So image (PGS) and styled-text (ASS) subtitles are simply
// invisible to it. This module is a small, purpose-built EBML reader that:
//
//   - enumerates ALL tracks, including subtitles, with their CodecID,
//     CodecPrivate, language, name and content-compression flag;
//   - extracts the font attachments an ASS track needs;
//   - follows the playhead, reading clusters over HTTP Range and yielding the
//     selected subtitle track's blocks (inflating zlib when needed) with
//     absolute millisecond timestamps.
//
// It deliberately reads whole clusters (one Range request each) rather than
// hunting individual blocks: on localhost the bytes are already in the OS page
// cache from Mediabunny's own read of the same file, so the redundancy is
// nearly free and the code stays simple. Seeking uses the Cues index when the
// file has one, falling back to a linear cluster walk.

// ---- EBML element IDs ------------------------------------------------------

const ID = {
    Segment: 0x18538067,
    SeekHead: 0x114d9b74,
    Seek: 0x4dbb,
    SeekID: 0x53ab,
    SeekPosition: 0x53ac,
    Info: 0x1549a966,
    TimestampScale: 0x2ad7b1,
    Duration: 0x4489,
    Tracks: 0x1654ae6b,
    TrackEntry: 0xae,
    TrackNumber: 0xd7,
    TrackType: 0x83,
    CodecID: 0x86,
    CodecPrivate: 0x63a2,
    Name: 0x536e,
    Language: 0x22b59c,
    LanguageBCP47: 0x22b59d,
    ContentEncodings: 0x6d80,
    ContentEncoding: 0x6240,
    ContentCompression: 0x5034,
    ContentCompAlgo: 0x4254,
    ContentCompSettings: 0x4255,
    Cues: 0x1c53bb6b,
    CuePoint: 0xbb,
    CueTime: 0xb3,
    CueTrackPositions: 0xb7,
    CueClusterPosition: 0xf1,
    Cluster: 0x1f43b675,
    Timestamp: 0xe7,
    SimpleBlock: 0xa3,
    BlockGroup: 0xa0,
    Block: 0xa1,
    BlockDuration: 0x9b,
    Attachments: 0x1941a469,
    AttachedFile: 0x61a7,
    FileName: 0x466e,
    FileMimeType: 0x4660,
    FileData: 0x465c,
    Void: 0xec
}

// TrackType 17 == subtitle in Matroska.
const TRACK_TYPE_SUBTITLE = 0x11

// ---- low-level EBML primitives ---------------------------------------------

// Number of bytes in a vint, derived from the leading-zero run of byte 0.
function vintLen(first) {
    let mask = 0x80
    let len = 1
    while (len <= 8 && !(first & mask)) {
        mask >>= 1
        len++
    }
    return len
}

// Read an element ID at `pos` keeping its length-descriptor bits (IDs are
// compared as their full on-wire value).
function readId(buf, pos) {
    const len = vintLen(buf[pos])
    let v = 0
    for (let i = 0; i < len; i++) v = v * 256 + buf[pos + i]
    return { value: v, length: len }
}

// Read a data-size / general vint at `pos`, stripping the marker bit. Returns
// `unknown: true` when every value bit is set (the EBML "unknown size"
// sentinel), which file remuxes don't use but live captures do.
function readVint(buf, pos) {
    const len = vintLen(buf[pos])
    let v = buf[pos] & (0xff >> len)
    let allOnes = v === 0xff >> len
    for (let i = 1; i < len; i++) {
        v = v * 256 + buf[pos + i]
        if (buf[pos + i] !== 0xff) allOnes = false
    }
    return { value: v, length: len, unknown: allOnes }
}

function readUInt(buf, start, end) {
    let v = 0
    for (let i = start; i < end; i++) v = v * 256 + buf[i]
    return v
}

function readFloat(buf, start, end) {
    const dv = new DataView(buf.buffer, buf.byteOffset + start, end - start)
    if (end - start === 4) return dv.getFloat32(0)
    if (end - start === 8) return dv.getFloat64(0)
    return readUInt(buf, start, end)
}

const td = new TextDecoder()

// ---- ranged HTTP reader ----------------------------------------------------

class RangeReader {
    constructor(url) {
        this.url = url
        this.fileSize = null
    }

    async read(offset, length) {
        const r = await fetch(this.url, { headers: { Range: `bytes=${offset}-${offset + length - 1}` } })
        if (!r.ok && r.status !== 206) throw new Error(`range ${offset}+${length} → HTTP ${r.status}`)
        const cr = r.headers.get("content-range")
        if (cr) {
            const m = /\/(\d+)\s*$/.exec(cr)
            if (m) this.fileSize = parseInt(m[1], 10)
        }
        return new Uint8Array(await r.arrayBuffer())
    }
}

// ---- zlib (raw deflate w/ zlib wrapper) via the platform DecompressionStream

async function inflateZlib(bytes) {
    const ds = new DecompressionStream("deflate")
    const stream = new Response(bytes).body.pipeThrough(ds)
    return new Uint8Array(await new Response(stream).arrayBuffer())
}

// ---- CodecID → kind --------------------------------------------------------

function codecKind(codecId) {
    if (!codecId) return "other"
    const c = codecId.toUpperCase()
    if (c === "S_HDMV/PGS") return "pgs"
    if (c === "S_TEXT/ASS" || c === "S_TEXT/SSA") return "ass"
    if (c === "S_TEXT/UTF8") return "srt"
    if (c === "S_TEXT/WEBVTT") return "vtt"
    if (c === "S_VOBSUB") return "vobsub"
    if (c.startsWith("S_DVBSUB")) return "dvbsub"
    return "other"
}

// ---- public entry point ----------------------------------------------------

// Open `rawUrl` (a /api/raw URL) and parse just enough of the Matroska header
// to enumerate subtitle tracks. Returns an `MkvSubtitles` or `null` when the
// file isn't Matroska (a quick magic-byte check) so callers can no-op on MP4.
export async function openMkvSubtitles(rawUrl) {
    const reader = new RangeReader(rawUrl)
    const head = await reader.read(0, 64 * 1024)
    // EBML header magic: 0x1A45DFA3.
    if (!(head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3)) {
        return null
    }
    const mkv = new MkvSubtitles(reader)
    await mkv._parseHeader(head)
    return mkv
}

class MkvSubtitles {
    constructor(reader) {
        this.reader = reader
        this.timestampScale = 1_000_000 // ns/tick → default 1ms
        this.durationSec = 0
        this.tracks = [] // all tracks; callers filter by .type
        this.segmentDataStart = 0
        this.firstClusterOffset = null
        this.cues = [] // [{ timeSec, clusterOffset }] absolute file offsets
        this._attachmentsOffset = null
        this._seekHead = {} // ID → absolute offset (from SeekHead)
        // Cluster cursor for the playhead-following reader.
        this._cursorOffset = null
        this._cursorAtEnd = false
    }

    subtitleTracks() {
        return this.tracks.filter((t) => t.type === TRACK_TYPE_SUBTITLE)
    }

    // ---- header parse ------------------------------------------------------

    async _parseHeader(head) {
        // Locate the Segment within the first chunk (EBML header is small).
        let pos = 0
        let segStart = -1
        while (pos < head.length - 4) {
            const id = readId(head, pos)
            if (id.value === ID.Segment) {
                segStart = pos
                break
            }
            // Walk the EBML header's children by size to reach the Segment.
            const sz = readVint(head, pos + id.length)
            pos += id.length + sz.length + (sz.unknown ? 0 : sz.value)
            if (sz.unknown) {
                pos++ // shouldn't happen in the EBML header
            }
        }
        if (segStart < 0) throw new Error("no Segment element")
        const segId = readId(head, segStart)
        const segSz = readVint(head, segStart + segId.length)
        this.segmentDataStart = segStart + segId.length + segSz.length

        // Walk Segment top-level children sequentially until the first Cluster,
        // capturing Info/Tracks/SeekHead/Cues/Attachments as we pass them.
        let off = this.segmentDataStart
        let guard = 0
        while (guard++ < 10000) {
            const hdr = await this.reader.read(off, 16)
            if (hdr.length < 2) break
            const id = readId(hdr, 0)
            const sz = readVint(hdr, id.length)
            const contentStart = off + id.length + sz.length
            if (id.value === ID.Cluster) {
                this.firstClusterOffset = off
                break
            }
            if (sz.unknown) break
            if (id.value === ID.Info) await this._parseInfo(contentStart, sz.value)
            else if (id.value === ID.Tracks) await this._parseTracks(contentStart, sz.value)
            else if (id.value === ID.SeekHead) await this._parseSeekHead(contentStart, sz.value)
            else if (id.value === ID.Cues) await this._parseCues(contentStart, sz.value)
            else if (id.value === ID.Attachments) this._attachmentsOffset = { start: contentStart, size: sz.value }
            off = contentStart + sz.value
        }

        // Cues usually live after the clusters; if we didn't pass them, consult
        // the SeekHead and parse them by a direct read.
        if (this.cues.length === 0 && this._seekHead[ID.Cues] != null) {
            const cuesOff = this._seekHead[ID.Cues]
            const hdr = await this.reader.read(cuesOff, 16)
            const id = readId(hdr, 0)
            if (id.value === ID.Cues) {
                const sz = readVint(hdr, id.length)
                await this._parseCues(cuesOff + id.length + sz.length, sz.value)
            }
        }
        // Same for Tracks / Attachments if the linear walk somehow missed them.
        if (this.tracks.length === 0 && this._seekHead[ID.Tracks] != null) {
            const o = this._seekHead[ID.Tracks]
            const hdr = await this.reader.read(o, 16)
            const id = readId(hdr, 0)
            if (id.value === ID.Tracks) {
                const sz = readVint(hdr, id.length)
                await this._parseTracks(o + id.length + sz.length, sz.value)
            }
        }
        if (this._attachmentsOffset == null && this._seekHead[ID.Attachments] != null) {
            const o = this._seekHead[ID.Attachments]
            const hdr = await this.reader.read(o, 16)
            const id = readId(hdr, 0)
            if (id.value === ID.Attachments) {
                const sz = readVint(hdr, id.length)
                this._attachmentsOffset = { start: o + id.length + sz.length, size: sz.value }
            }
        }
    }

    async _parseInfo(start, size) {
        const buf = await this.reader.read(start, size)
        let i = 0
        while (i < buf.length) {
            const id = readId(buf, i)
            const sz = readVint(buf, i + id.length)
            const cs = i + id.length + sz.length
            const ce = cs + sz.value
            if (id.value === ID.TimestampScale) this.timestampScale = readUInt(buf, cs, ce)
            else if (id.value === ID.Duration) this._rawDuration = readFloat(buf, cs, ce)
            i = ce
        }
        if (this._rawDuration) this.durationSec = (this._rawDuration * this.timestampScale) / 1e9
    }

    async _parseSeekHead(start, size) {
        const buf = await this.reader.read(start, size)
        let i = 0
        while (i < buf.length) {
            const id = readId(buf, i)
            const sz = readVint(buf, i + id.length)
            const cs = i + id.length + sz.length
            const ce = cs + sz.value
            if (id.value === ID.Seek) {
                let j = cs
                let seekId = null
                let seekPos = null
                while (j < ce) {
                    const sid = readId(buf, j)
                    const ssz = readVint(buf, j + sid.length)
                    const scs = j + sid.length + ssz.length
                    const sce = scs + ssz.value
                    if (sid.value === ID.SeekID) seekId = readUInt(buf, scs, sce)
                    else if (sid.value === ID.SeekPosition) seekPos = readUInt(buf, scs, sce)
                    j = sce
                }
                if (seekId != null && seekPos != null) {
                    this._seekHead[seekId] = this.segmentDataStart + seekPos
                }
            }
            i = ce
        }
    }

    async _parseTracks(start, size) {
        const buf = await this.reader.read(start, size)
        let i = 0
        while (i < buf.length) {
            const id = readId(buf, i)
            const sz = readVint(buf, i + id.length)
            const cs = i + id.length + sz.length
            const ce = cs + sz.value
            if (id.value === ID.TrackEntry) this.tracks.push(this._parseTrackEntry(buf, cs, ce))
            i = ce
        }
    }

    _parseTrackEntry(buf, start, end) {
        const t = {
            number: null,
            type: null,
            codecId: null,
            codecPrivate: null,
            name: null,
            language: "und",
            compressed: false,
            compAlgo: null,
            kind: "other"
        }
        let i = start
        while (i < end) {
            const id = readId(buf, i)
            const sz = readVint(buf, i + id.length)
            const cs = i + id.length + sz.length
            const ce = cs + sz.value
            switch (id.value) {
                case ID.TrackNumber:
                    t.number = readUInt(buf, cs, ce)
                    break
                case ID.TrackType:
                    t.type = readUInt(buf, cs, ce)
                    break
                case ID.CodecID:
                    t.codecId = td.decode(buf.slice(cs, ce))
                    break
                case ID.CodecPrivate:
                    t.codecPrivate = buf.slice(cs, ce)
                    break
                case ID.Name:
                    t.name = td.decode(buf.slice(cs, ce))
                    break
                case ID.Language:
                    t.language = td.decode(buf.slice(cs, ce))
                    break
                case ID.LanguageBCP47:
                    t.language = td.decode(buf.slice(cs, ce))
                    break
                case ID.ContentEncodings:
                    this._parseContentEncodings(buf, cs, ce, t)
                    break
            }
            i = ce
        }
        t.kind = codecKind(t.codecId)
        return t
    }

    _parseContentEncodings(buf, start, end, t) {
        // Walk down ContentEncodings → ContentEncoding → ContentCompression →
        // ContentCompAlgo. Algo 0 == zlib (the only one we handle / that PGS
        // tracks use in practice).
        let i = start
        while (i < end) {
            const id = readId(buf, i)
            const sz = readVint(buf, i + id.length)
            const cs = i + id.length + sz.length
            const ce = cs + sz.value
            if (id.value === ID.ContentEncoding) {
                this._parseContentEncodings(buf, cs, ce, t) // recurse into children
            } else if (id.value === ID.ContentCompression) {
                // A ContentCompression element means the track is compressed;
                // ContentCompAlgo defaults to 0 (zlib) when omitted — which is
                // exactly how these PGS tracks are authored.
                t.compressed = true
                if (t.compAlgo == null) t.compAlgo = 0
                this._parseContentEncodings(buf, cs, ce, t)
            } else if (id.value === ID.ContentCompAlgo) {
                t.compressed = true
                t.compAlgo = readUInt(buf, cs, ce)
            }
            i = ce
        }
    }

    async _parseCues(start, size) {
        const buf = await this.reader.read(start, size)
        let i = 0
        while (i < buf.length) {
            const id = readId(buf, i)
            const sz = readVint(buf, i + id.length)
            const cs = i + id.length + sz.length
            const ce = cs + sz.value
            if (id.value === ID.CuePoint) {
                let j = cs
                let cueTime = null
                let clusterPos = null
                while (j < ce) {
                    const cid = readId(buf, j)
                    const csz = readVint(buf, j + cid.length)
                    const ccs = j + cid.length + csz.length
                    const cce = ccs + csz.value
                    if (cid.value === ID.CueTime) {
                        cueTime = readUInt(buf, ccs, cce)
                    } else if (cid.value === ID.CueTrackPositions) {
                        // Take the first CueClusterPosition we find — cluster
                        // offsets are shared across tracks within a CuePoint.
                        let k = ccs
                        while (k < cce) {
                            const tid = readId(buf, k)
                            const tsz = readVint(buf, k + tid.length)
                            const tcs = k + tid.length + tsz.length
                            const tce = tcs + tsz.value
                            if (tid.value === ID.CueClusterPosition && clusterPos == null) {
                                clusterPos = readUInt(buf, tcs, tce)
                            }
                            k = tce
                        }
                    }
                    j = cce
                }
                if (cueTime != null && clusterPos != null) {
                    this.cues.push({
                        timeSec: (cueTime * this.timestampScale) / 1e9,
                        clusterOffset: this.segmentDataStart + clusterPos
                    })
                }
            }
            i = ce
        }
        this.cues.sort((a, b) => a.timeSec - b.timeSec)
    }

    // ---- attachments (fonts) ----------------------------------------------

    // Read and return every embedded file (fonts, mostly). Lazy — only called
    // when an ASS track is selected, since this can be tens of MB.
    async getAttachments() {
        if (this._attachmentsOffset == null) return []
        const { start, size } = this._attachmentsOffset
        const buf = await this.reader.read(start, size)
        const out = []
        let i = 0
        while (i < buf.length) {
            const id = readId(buf, i)
            const sz = readVint(buf, i + id.length)
            const cs = i + id.length + sz.length
            const ce = cs + sz.value
            if (id.value === ID.AttachedFile) {
                let j = cs
                let filename = null
                let mime = null
                let data = null
                while (j < ce) {
                    const fid = readId(buf, j)
                    const fsz = readVint(buf, j + fid.length)
                    const fcs = j + fid.length + fsz.length
                    const fce = fcs + fsz.value
                    if (fid.value === ID.FileName) filename = td.decode(buf.slice(fcs, fce))
                    else if (fid.value === ID.FileMimeType) mime = td.decode(buf.slice(fcs, fce))
                    else if (fid.value === ID.FileData) data = buf.slice(fcs, fce)
                    j = fce
                }
                if (data) out.push({ filename, mime, data })
            }
            i = ce
        }
        return out
    }

    // ---- playhead-following block reader -----------------------------------

    // Position the cluster cursor at (or just before) `timeSec`, using Cues
    // when available, else the first cluster.
    seek(timeSec) {
        if (this.cues.length > 0) {
            let chosen = this.cues[0]
            for (const c of this.cues) {
                if (c.timeSec <= timeSec + 0.001) chosen = c
                else break
            }
            this._cursorOffset = chosen.clusterOffset
        } else {
            this._cursorOffset = this.firstClusterOffset
        }
        this._cursorAtEnd = this._cursorOffset == null
    }

    // Read the next cluster from the cursor and return the selected track's
    // blocks within it. Returns `null` once past the last cluster. Each block:
    // { startMs, durationMs|null, payload: Uint8Array }. Inflates zlib when the
    // track is compressed.
    async nextCluster(trackNumber) {
        if (this._cursorAtEnd || this._cursorOffset == null) return null
        const off = this._cursorOffset
        const hdr = await this.reader.read(off, 16)
        if (hdr.length < 4) {
            this._cursorAtEnd = true
            return null
        }
        const id = readId(hdr, 0)
        if (id.value !== ID.Cluster) {
            // Walked off the cluster chain (hit Cues/Tags/etc at the tail).
            this._cursorAtEnd = true
            return null
        }
        const sz = readVint(hdr, id.length)
        const contentStart = off + id.length + sz.length
        if (sz.unknown) {
            this._cursorAtEnd = true
            return null
        }
        const buf = await this.reader.read(contentStart, sz.value)
        this._cursorOffset = contentStart + sz.value

        let clusterTs = 0
        const blocks = []
        let i = 0
        while (i < buf.length) {
            const eid = readId(buf, i)
            const esz = readVint(buf, i + eid.length)
            const cs = i + eid.length + esz.length
            const ce = cs + esz.value
            if (eid.value === ID.Timestamp) {
                clusterTs = readUInt(buf, cs, ce)
            } else if (eid.value === ID.SimpleBlock) {
                const b = this._readBlock(buf, cs, ce, trackNumber, clusterTs, null)
                if (b) blocks.push(b)
            } else if (eid.value === ID.BlockGroup) {
                let j = cs
                let dur = null
                let blockStart = -1
                let blockEnd = -1
                while (j < ce) {
                    const bid = readId(buf, j)
                    const bsz = readVint(buf, j + bid.length)
                    const bcs = j + bid.length + bsz.length
                    const bce = bcs + bsz.value
                    if (bid.value === ID.Block) {
                        blockStart = bcs
                        blockEnd = bce
                    } else if (bid.value === ID.BlockDuration) {
                        dur = readUInt(buf, bcs, bce)
                    }
                    j = bce
                }
                if (blockStart >= 0) {
                    const b = this._readBlock(buf, blockStart, blockEnd, trackNumber, clusterTs, dur)
                    if (b) blocks.push(b)
                }
            }
            i = ce
        }

        // Inflate any compressed payloads (PGS). Done after the structural walk
        // so the per-block await doesn't stall cluster parsing.
        const track = this.tracks.find((t) => t.number === trackNumber)
        if (track && track.compressed && track.compAlgo === 0) {
            for (const b of blocks) {
                try {
                    b.payload = await inflateZlib(b.payload)
                } catch (e) {
                    b.error = e.message
                }
            }
        }
        return { clusterTimeSec: (clusterTs * this.timestampScale) / 1e9, blocks }
    }

    // Parse a (Simple)Block's header, keeping it only when it belongs to
    // `trackNumber`. Returns the block descriptor or null. Laced blocks (rare
    // for subtitles) are not split — the whole frame area is returned, which is
    // correct for the unlaced case.
    _readBlock(buf, start, end, trackNumber, clusterTs, dur) {
        const tn = readVint(buf, start)
        if (tn.value !== trackNumber) return null
        let p = start + tn.length
        const relTs = (buf[p] << 8) | buf[p + 1]
        // 16-bit signed relative timestamp.
        const rel = relTs >= 0x8000 ? relTs - 0x10000 : relTs
        const flags = buf[p + 2]
        p += 3
        const lacing = (flags >> 1) & 0x3
        if (lacing !== 0) {
            // Skip the lacing frame-count byte; subtitle tracks effectively
            // never lace, so we don't split — just advance past the count.
            p += 1
        }
        const ts = this.timestampScale
        return {
            startMs: ((clusterTs + rel) * ts) / 1e6,
            durationMs: dur != null ? (dur * ts) / 1e6 : null,
            payload: buf.slice(p, end)
        }
    }
}
