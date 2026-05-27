// Client-side WebCodecs player. Mediabunny demuxes the file over HTTP Range
// requests; WebCodecs decodes; the video frames go to a canvas, the audio
// frames are scheduled into the AudioContext clock, which is the master clock.
//
// Public entry point: `startPlayer({ host, manifest, ...callbacks })`.
// Returns a controller with play/pause/seek/dispose.

import { Input, UrlSource, ALL_FORMATS, EncodedPacketSink, AudioSampleSink } from "/vendor/mediabunny.mjs"
import { registerAc3Decoder } from "/vendor/mediabunny-ac3.mjs"

// Register the AC-3 / E-AC-3 WASM fallback decoder with Mediabunny's custom-
// decoder registry. Chrome's WebCodecs `AudioDecoder` doesn't ship Dolby
// codecs in many builds; with this registration `AudioSampleSink` transparently
// uses the WASM decoder for those codec strings while still using native
// WebCodecs for AAC/Opus/etc. Idempotent — safe to call at every module load.
registerAc3Decoder()

// How many decoded video frames to keep queued ahead of the audio clock before
// we pause feeding the decoder. Keeps memory bounded on long fast scrubs.
const VIDEO_FRAME_QUEUE_TARGET = 24
// How far ahead (seconds) of `audioCtx.currentTime` we'll pre-schedule audio
// buffer sources. Larger = more resilient to main-thread jank but more pending
// state to tear down on seek.
const AUDIO_SCHEDULE_LOOKAHEAD_S = 0.5
// `decoder.decodeQueueSize` cap — the *real* input-side backpressure signal.
// `decode()` is synchronous so we can hammer the decoder with chunks faster
// than it produces output frames; the only way to slow ourselves down before
// the decoder has caught up is to watch its own pending-input counter.
const DECODER_QUEUE_CAP = 30
// `requestAnimationFrame` cadence on the user's display is usually 60 Hz; the
// presentation loop runs every rAF and only draws when a frame is due.

export async function startPlayer({ host, manifest, startAt, startAudioOrd, onTimeUpdate, onDurationChange, onEnded, onError }) {
    const ctl = new PlayerController({
        host,
        manifest,
        startAt,
        startAudioOrd,
        onTimeUpdate,
        onDurationChange,
        onEnded,
        onError
    })
    await ctl.boot()
    return ctl
}

class PlayerController extends EventTarget {
    constructor({ host, manifest, startAt, startAudioOrd, onTimeUpdate, onDurationChange, onEnded, onError }) {
        super()
        this.host = host
        this.manifest = manifest
        this.startAt = startAt || 0
        // Which audio track to use at boot (0-based ordinal among audio
        // tracks). `null`/undefined falls back to mediabunny's primary —
        // whichever the file marks as default — which can disagree with
        // the caller's "prefer English" preference.
        this.startAudioOrd = startAudioOrd ?? null
        this.onTimeUpdate = onTimeUpdate || (() => {})
        this.onDurationChange = onDurationChange || (() => {})
        this.onEnded = onEnded || (() => {})
        this.onError = onError || ((e) => console.error("[player]", e))

        // HTMLMediaElement-shaped state. Kept as simple fields so the existing
        // controls bar (designed against a <video> element) can stay almost
        // untouched: it reads .currentTime / .duration / .paused / .muted /
        // .volume and listens for 'timeupdate' / 'play' / 'pause' / 'ended' /
        // 'durationchange' / 'volumechange' / 'loadedmetadata' events.
        this._muted = false
        this._volume = 1
        this._paused = true
        this._ended = false

        this.disposed = false

        // Mediabunny input + tracks
        this.input = null
        this.videoTrack = null
        this.audioTrack = null
        this.videoSink = null
        this.audioSink = null

        // WebCodecs video decoder (audio goes through Mediabunny's
        // AudioSampleSink, which uses WebCodecs internally for supported
        // codecs and the registered WASM decoder for AC-3 / E-AC-3).
        this.videoDecoder = null

        // Audio playback
        this.audioCtx = null
        this.audioGain = null
        // First-frame-of-segment audio media time (seconds). Used to convert
        // audioCtx.currentTime into media-time for the master clock.
        this.audioBaseMediaTime = 0
        // The audioCtx.currentTime at which `audioBaseMediaTime` was scheduled.
        this.audioBaseCtxTime = 0
        // Wall-clock time the next pending audio buffer should start at, in
        // ctx-time units. Advanced as we schedule new buffers.
        this.audioNextCtxTime = 0
        // Live AudioBufferSourceNodes we may need to stop on seek.
        this.liveAudioSources = new Set()

        // Video presentation
        this.canvas = null
        this.canvasCtx = null
        this.videoFrameQueue = []
        this.rafId = null

        // Pump tasks — promises we can wait on for orderly teardown
        this.videoPumpAbort = null
        this.audioPumpAbort = null
        this.videoPumpDone = null
        this.audioPumpDone = null

        // Generation counter — bumped on every seek so stale pump iterations
        // can detect they should bail out.
        this.gen = 0

        // Cached duration (seconds).
        this._duration = manifest.duration || 0
        this._ready = false

        // Last-known media time emitted via onTimeUpdate, for throttling.
        this._lastEmittedTime = -1
    }

    async boot() {
        // Volume control: separate GainNode so the controls bar can poke it
        // without rebuilding the graph on every track switch.
        this.audioCtx = new AudioContext()
        this.audioGain = this.audioCtx.createGain()
        this.audioGain.connect(this.audioCtx.destination)
        // Initial paused-ness mirrors the AudioContext state. The statechange
        // handler below keeps `_paused` in sync from then on and emits the
        // play/pause events the UI listens for.
        this._paused = this.audioCtx.state !== "running"
        console.log(`[player] audioCtx state at boot: ${this.audioCtx.state}`)
        this.audioCtx.addEventListener("statechange", () => {
            console.log(`[player] audioCtx statechange -> ${this.audioCtx.state}`)
            const wasPaused = this._paused
            this._paused = this.audioCtx.state !== "running"
            if (this._paused !== wasPaused) {
                this.dispatchEvent(new Event(this._paused ? "pause" : "play"))
            }
        })

        // Open the source. UrlSource issues ranged fetches as Mediabunny needs
        // bytes; it's HTTP-driven, no preflight download.
        this.input = new Input({
            formats: ALL_FORMATS,
            source: new UrlSource(this.manifest.raw_url)
        })

        try {
            const readable = await this.input.canRead()
            if (!readable) throw new Error("file not readable")
        } catch (e) {
            this.onError(`couldn't open file: ${e.message}`)
            return
        }

        // Build the canvas + audio graph based on what's actually in the file.
        this.videoTrack = await this.input.getPrimaryVideoTrack()
        if (this.startAudioOrd !== null) {
            const tracks = await this.input.getTracks()
            const audioTracks = tracks.filter((t) => t.isAudioTrack())
            this.audioTrack = audioTracks[this.startAudioOrd] || audioTracks[0] || null
        } else {
            this.audioTrack = await this.input.getPrimaryAudioTrack()
        }

        // Probe duration via mediabunny if the server-supplied manifest was
        // missing it.
        if (!this._duration) {
            this._duration = (await this.input.computeDuration?.()) || 0
        }
        if (this._duration > 0) {
            this.onDurationChange(this._duration)
            this.dispatchEvent(new Event("durationchange"))
        }

        if (this.videoTrack) {
            await this._setupVideo()
            if (this.disposed) return
        }
        if (this.audioTrack) {
            await this._setupAudio()
            if (this.disposed) return
        }

        if (!this.videoTrack && !this.audioTrack) {
            this.onError("no decodable video or audio tracks in this file")
            return
        }

        // Metadata is ready (codec configs known, duration known); existing
        // controls fire their resume-restore logic on `loadedmetadata`.
        this._ready = true
        this.dispatchEvent(new Event("loadedmetadata"))

        // Seed the pumps at the requested start time (resume support).
        await this._restartAtTime(this.startAt)

        // Diagnostic heartbeat — only when `?debug=1` is in the URL, so the
        // steady-state log stays quiet but we can flip it on whenever the
        // player misbehaves.
        if (new URLSearchParams(location.search).has("debug")) {
            this._heartbeatId = setInterval(() => {
                if (this.disposed) return
                console.log(
                    `[player] hb: state=${this.audioCtx?.state} ` +
                        `media=${this.currentTime.toFixed(2)}s ` +
                        `vq=${this.videoFrameQueue.length} ` +
                        `audioAhead=${(this.audioNextCtxTime - (this.audioCtx?.currentTime ?? 0)).toFixed(2)}s ` +
                        `liveAudio=${this.liveAudioSources.size}`
                )
            }, 2000)
        }
    }

    async _setupVideo() {
        const cfg = await this.videoTrack.getDecoderConfig()
        if (!cfg) {
            this.onError(`unknown video codec: ${await this.videoTrack.getCodec()}`)
            return
        }
        console.log(
            `[player] video config: codec=${cfg.codec} ` +
                `coded=${cfg.codedWidth}x${cfg.codedHeight} ` +
                `description=${cfg.description ? `${cfg.description.byteLength}B` : "none"}`
        )
        const { supported } = await VideoDecoder.isConfigSupported(cfg)
        if (!supported) {
            const codec = await this.videoTrack.getCodec()
            this.onError(`this browser can't decode ${codec} (${cfg.codec}). try Safari or Chrome.`)
            return
        }

        const w = await this.videoTrack.getDisplayWidth()
        const h = await this.videoTrack.getDisplayHeight()
        this.canvas = document.createElement("canvas")
        this.canvas.width = w
        this.canvas.height = h
        this.canvas.className = "player-canvas"
        this.canvasCtx = this.canvas.getContext("2d")
        this.host.appendChild(this.canvas)

        // Save a copy of the config so reconfigure-on-decoder-reset works.
        this.videoConfig = cfg
        this.videoDecoder = new VideoDecoder({
            output: (frame) => this._onVideoFrame(frame),
            error: (e) => {
                console.warn(
                    `[player] video decoder error name=${e.name} message=${e.message} ` + `state=${this.videoDecoder?.state}`
                )
                this.onError(`video decoder error: ${e.message || e.name}`)
            }
        })
        this.videoDecoder.configure(cfg)

        this.videoSink = new EncodedPacketSink(this.videoTrack)
    }

    async _setupAudio() {
        // Mediabunny's AudioSampleSink decodes the track for us — internally
        // it uses WebCodecs `AudioDecoder` for codecs it supports (AAC, Opus,
        // FLAC, …) and the registered custom WASM decoder for AC-3 / E-AC-3.
        // No separate `AudioDecoder.isConfigSupported` precheck because the
        // sink reports failures via empty iteration; a single code path
        // handles every audio codec.
        try {
            this.audioSink = new AudioSampleSink(this.audioTrack)
            const codec = await this.audioTrack.getCodec()
            console.log(`[player] audio sink: codec=${codec}`)
        } catch (e) {
            console.warn(`[player] audio sink setup failed: ${e.message}; muting audio`)
            this.audioTrack = null
        }
    }

    /**
     * Swap to a different audio track without disturbing video playback.
     * `ordinal` is the 0-based position among audio tracks (audio_tracks[N]
     * in the manifest). We don't use mediabunny's `track.id` field for the
     * match because that's the *container* track ID (tkhd ID in MP4, Matroska
     * TrackNumber) which doesn't agree with ffprobe's stream `index` — the
     * file order they both produce IS reliable, so we match on that.
     * Video keeps decoding; only the audio decoder + sink + pump get torn
     * down and rebuilt at the current play position.
     */
    async switchAudio(ordinal) {
        if (this.disposed) return
        const tracks = await this.input.getTracks()
        const audioTracks = tracks.filter((t) => t.isAudioTrack())
        const target = audioTracks[ordinal]
        if (!target) {
            console.warn(`[player] switchAudio: no audio track at ordinal=${ordinal} (have ${audioTracks.length})`)
            return
        }
        if (target === this.audioTrack) return
        console.log(`[player] switching audio to ordinal=${ordinal}`)

        const resumeAt = this.currentTime
        // Stop just the audio pump via its abort signal — gen stays put so
        // the video pump keeps running. The video pump won't see any
        // disruption; only the audio path gets rebuilt.
        if (this.audioPumpAbort) this.audioPumpAbort()
        await Promise.allSettled([this.audioPumpDone].filter(Boolean))
        const gen = this.gen

        // Stop in-flight scheduled audio (the old track's buffers).
        for (const s of this.liveAudioSources) {
            try {
                s.stop()
            } catch (_) {
                void _
            }
        }
        this.liveAudioSources.clear()

        // Drop the old sink; the new one is created in _setupAudio.
        this.audioSink = null

        // Wire up the new track.
        this.audioTrack = target
        await this._setupAudio()
        if (this.disposed || gen !== this.gen) return
        if (!this.audioTrack) {
            console.warn("[player] switchAudio: new track not decodable")
            return
        }

        // Rebase the clock so the new pump seeds correctly. Video pump is
        // untouched and continues against the existing clock — we just shift
        // the base so the new audio packets schedule at the right ctx time.
        this.audioBaseMediaTime = resumeAt
        this.audioBaseCtxTime = this.audioCtx.currentTime
        this.audioNextCtxTime = this.audioBaseCtxTime

        // Spawn fresh audio pump.
        const { promise, abort } = makeAbortable((signal) => this._pumpAudio(resumeAt, gen, signal))
        this.audioPumpDone = promise
        this.audioPumpAbort = abort
    }

    // ---- pump lifecycle ----------------------------------------------------

    async _restartAtTime(t) {
        this.gen += 1
        const gen = this.gen

        // Stop any running pumps and drop queued state.
        if (this.videoPumpAbort) this.videoPumpAbort()
        if (this.audioPumpAbort) this.audioPumpAbort()
        await Promise.allSettled([this.videoPumpDone, this.audioPumpDone].filter(Boolean))

        // Drop already-decoded video frames.
        for (const f of this.videoFrameQueue) f.close()
        this.videoFrameQueue = []

        // Stop in-flight audio.
        for (const s of this.liveAudioSources) {
            try {
                s.stop()
            } catch (_) {
                void _
            }
        }
        this.liveAudioSources.clear()

        // Discard pending decoder work without emitting output. We do NOT
        // use flush() here: flush() processes pending input and emits any
        // remaining decoded frames, which on a backward seek would prepend
        // future-timestamp frames to an otherwise-cleared queue, blocking
        // the present loop (which only dequeues frames whose timestamp <=
        // mediaTime). reset() throws those packets away and demotes the
        // decoder to "unconfigured" — we configure() it again right after.
        if (this.videoDecoder?.state === "configured") {
            try {
                this.videoDecoder.reset()
                this.videoDecoder.configure(this.videoConfig)
            } catch (e) {
                console.warn("[player] videoDecoder reset/configure threw", e)
            }
        }
        // Audio side: Mediabunny's AudioSampleSink is stateless across
        // iterators — the pump-restart below spawns a fresh `samples()`
        // iterator at the new start time, which handles seeking internally.
        // Nothing to reset here.

        if (this.disposed || gen !== this.gen) return

        // Reset the clock — we want media-time `t` to map to current ctx-time.
        this.audioBaseMediaTime = t
        this.audioBaseCtxTime = this.audioCtx.currentTime
        this.audioNextCtxTime = this.audioBaseCtxTime

        // Spawn fresh pumps.
        if (this.videoTrack) {
            const { promise, abort } = makeAbortable((signal) => this._pumpVideo(t, gen, signal))
            this.videoPumpDone = promise
            this.videoPumpAbort = abort
        }
        if (this.audioTrack) {
            const { promise, abort } = makeAbortable((signal) => this._pumpAudio(t, gen, signal))
            this.audioPumpDone = promise
            this.audioPumpAbort = abort
        }

        // Kick the presentation rAF loop.
        if (this.rafId == null) this._presentLoop()
    }

    async _pumpVideo(startTime, gen, signal) {
        let pkt = await this.videoSink.getKeyPacket(startTime)
        if (!pkt) {
            console.warn(`[player] no key packet at/before t=${startTime.toFixed(2)}s`)
            return
        }
        console.log(
            `[player] video pump: starting at t=${startTime.toFixed(2)}s ` +
                `(first key packet t=${pkt.timestamp.toFixed(3)}s, ` +
                `type=${pkt.type}, ${pkt.byteLength}B)`
        )
        // The clearing of stale frames is handled in _onVideoFrame: anything
        // whose timestamp is below startTime gets dropped silently.
        this._discardFramesBefore = startTime
        while (pkt && !signal.aborted && gen === this.gen) {
            // Two backpressure gates, both must clear:
            //   (a) videoFrameQueue length — bounds memory after decode.
            //   (b) videoDecoder.decodeQueueSize — bounds in-flight decode()
            //       calls. `decode()` is synchronous so without (b) we'd hand
            //       the decoder thousands of chunks before it produced a single
            //       frame, defeating (a).
            while (!signal.aborted && gen === this.gen) {
                const outFull = this.videoFrameQueue.length >= VIDEO_FRAME_QUEUE_TARGET
                const inFull = this.videoDecoder.decodeQueueSize >= DECODER_QUEUE_CAP
                if (!outFull && !inFull) break
                await sleep(16)
            }
            if (signal.aborted || gen !== this.gen) break
            try {
                this.videoDecoder.decode(pkt.toEncodedVideoChunk())
            } catch (e) {
                console.warn(`[player] video decode threw at t=${pkt.timestamp.toFixed(3)}s`, e)
                break
            }
            pkt = await this.videoSink.getNextPacket(pkt)
        }
        if (!signal.aborted && gen === this.gen) {
            // End of stream — flush the decoder so the last frames come out.
            try {
                await this.videoDecoder.flush()
            } catch (_) {
                void _
            }
        }
    }

    async _pumpAudio(startTime, gen, signal) {
        // AudioSampleSink does the demux + decode in one step. We get
        // already-decoded `AudioSample`s back; backpressure is *pull*-based —
        // we just don't pull the next sample until we have room. No separate
        // decoder-input queue to watch because the iterator owns it.
        //
        // Files with a leading audio gap (Matroska where audio starts mid-
        // movie) iterate from the first sample regardless of `startTime`;
        // the audio scheduler clamps any sample landing in the past, so a
        // 10s gap just delays audio onset and video plays through.
        let iter
        try {
            iter = this.audioSink.samples(startTime)
        } catch (e) {
            console.warn(`[player] audio sink samples() threw: ${e.message}`)
            return
        }
        let yielded = 0
        try {
            for await (const sample of iter) {
                if (signal.aborted || gen !== this.gen) {
                    sample.close()
                    break
                }
                if (yielded === 0) {
                    console.log(
                        `[player] audio pump: first sample at t=${sample.timestamp.toFixed(3)}s ` +
                            `(${sample.numberOfChannels}ch, ${sample.sampleRate}Hz, ${sample.numberOfFrames} frames)`
                    )
                }
                yielded++
                // Two backpressure gates, either parks the pump:
                //   (a) scheduled audio ahead of the clock — buffered enough.
                //   (b) liveAudioSources cap — main-thread cost of tracking
                //       N pending AudioBufferSourceNodes stalls the clock
                //       above ~hundreds of live sources.
                while (!signal.aborted && gen === this.gen) {
                    const ahead = this.audioNextCtxTime - this.audioCtx.currentTime
                    const aheadFull = ahead > AUDIO_SCHEDULE_LOOKAHEAD_S
                    const liveFull = this.liveAudioSources.size >= 100
                    if (!aheadFull && !liveFull) break
                    await sleep(20)
                }
                if (signal.aborted || gen !== this.gen) {
                    sample.close()
                    break
                }
                this._onAudioSample(sample)
            }
        } catch (e) {
            if (!signal.aborted) console.warn(`[player] audio sample iter threw: ${e.message}`)
        } finally {
            // For-await-of cleans up on `break`, but if we exited via `return`
            // or threw, explicitly close the iterator to free decoder
            // resources (per Mediabunny's docs).
            try {
                await iter.return?.()
            } catch (_) {
                void _
            }
        }
    }

    // ---- WebCodecs output callbacks ----------------------------------------

    _onVideoFrame(frame) {
        if (this.disposed) {
            frame.close()
            return
        }
        const tSec = frame.timestamp / 1e6
        if (tSec + 0.001 < this._discardFramesBefore) {
            frame.close()
            return
        }
        this.videoFrameQueue.push(frame)
    }

    _onAudioSample(sample) {
        if (this.disposed) {
            sample.close()
            return
        }
        const tSec = sample.timestamp
        // If this sample would land entirely in the past relative to our seek
        // target, drop it.
        if (tSec + sample.numberOfFrames / sample.sampleRate < this.audioBaseMediaTime) {
            sample.close()
            return
        }
        // Downmix to stereo. Web Audio's automatic "speakers" downmix only
        // covers mono/stereo/quad/5.1; for 7.1 it falls back to a discrete
        // copy that drops the center channel (where speech lives). We always
        // emit a 2-channel buffer to keep behavior consistent across layouts
        // and avoid implementation-specific quirks.
        const inChs = sample.numberOfChannels
        const frames = sample.numberOfFrames
        const buf = this.audioCtx.createBuffer(2, frames, sample.sampleRate)
        const L = new Float32Array(frames)
        const R = new Float32Array(frames)
        const planar = new Float32Array(frames)
        for (let inCh = 0; inCh < inChs; inCh++) {
            sample.copyTo(planar, { planeIndex: inCh, format: "f32-planar" })
            const [lG, rG] = downmixGains(inChs, inCh)
            if (lG !== 0) {
                for (let i = 0; i < frames; i++) L[i] += planar[i] * lG
            }
            if (rG !== 0) {
                for (let i = 0; i < frames; i++) R[i] += planar[i] * rG
            }
        }
        buf.copyToChannel(L, 0)
        buf.copyToChannel(R, 1)
        sample.close()
        const src = this.audioCtx.createBufferSource()
        src.buffer = buf
        src.connect(this.audioGain)
        const when = Math.max(this.audioCtx.currentTime, this._mediaToCtxTime(tSec))
        src.start(when)
        this.audioNextCtxTime = when + buf.duration
        this.liveAudioSources.add(src)
        src.onended = () => this.liveAudioSources.delete(src)
    }

    _mediaToCtxTime(mediaSec) {
        return this.audioBaseCtxTime + (mediaSec - this.audioBaseMediaTime)
    }

    _ctxToMediaTime(ctxSec) {
        return this.audioBaseMediaTime + (ctxSec - this.audioBaseCtxTime)
    }

    // ---- presentation loop -------------------------------------------------

    _presentLoop() {
        this.rafId = requestAnimationFrame(() => this._presentLoop())
        if (this.disposed) return
        const mediaTime = this.currentTime

        // Find the latest frame whose timestamp is <= mediaTime; drop earlier
        // frames; keep later ones for the next tick.
        let drew = null
        while (this.videoFrameQueue.length > 0) {
            const f = this.videoFrameQueue[0]
            const ft = f.timestamp / 1e6
            if (ft <= mediaTime + 0.001) {
                if (drew) drew.close()
                drew = this.videoFrameQueue.shift()
            } else {
                break
            }
        }
        if (drew && this.canvasCtx) {
            this.canvasCtx.drawImage(drew, 0, 0, this.canvas.width, this.canvas.height)
            drew.close()
        }

        // Time-update tick (throttled to ~4 Hz).
        if (Math.abs(mediaTime - this._lastEmittedTime) >= 0.25) {
            this._lastEmittedTime = mediaTime
            this.onTimeUpdate(mediaTime)
            this.dispatchEvent(new Event("timeupdate"))
        }

        // End-of-file detection: audio is exhausted (no scheduled sources)
        // AND video queue is empty AND we're past duration. Fire `ended` once.
        if (
            !this._ended &&
            this._duration > 0 &&
            mediaTime >= this._duration - 0.05 &&
            this.videoFrameQueue.length === 0 &&
            this.liveAudioSources.size === 0
        ) {
            this._ended = true
            this._paused = true
            this.onEnded()
            this.dispatchEvent(new Event("ended"))
        }
    }

    // ---- HTMLMediaElement-shaped API ---------------------------------------

    play() {
        if (this.disposed) return
        this._ended = false
        if (this.audioCtx.state === "suspended") {
            // CRITICAL: do NOT `await` audioCtx.resume(). Chrome's autoplay
            // policy makes the returned promise *pending indefinitely* if no
            // user gesture has happened — awaiting hangs the caller forever
            // (and the tap-to-play overlay in renderPlay never gets added).
            // Fire-and-forget; the statechange handler dispatches "play"
            // once the state actually transitions.
            this.audioCtx.resume().catch((e) => {
                console.warn(`[player] audioCtx.resume rejected: ${e.message}`)
            })
        }
    }

    pause() {
        if (this.disposed) return
        if (this.audioCtx.state === "running") {
            this.audioCtx.suspend().catch((e) => {
                console.warn(`[player] audioCtx.suspend rejected: ${e.message}`)
            })
        }
    }

    async seek(t) {
        if (this.disposed) return
        const clamped = Math.max(0, Math.min(t, this._duration || t))
        // Rebase the master clock *synchronously* so subsequent
        // `currentTime` reads return the new position immediately. Without
        // this, rapid back-to-back seeks (e.g. two Left presses) compute
        // their delta against the still-old getter value and collapse onto
        // the same target. `_restartAtTime` rebases again at the end of its
        // teardown sequence — this is just an early commit.
        this.audioBaseMediaTime = clamped
        this.audioBaseCtxTime = this.audioCtx.currentTime
        this.audioNextCtxTime = this.audioBaseCtxTime
        this.onTimeUpdate(clamped)
        this.dispatchEvent(new Event("timeupdate"))
        await this._restartAtTime(clamped)
    }

    get currentTime() {
        if (!this.audioCtx) return 0
        return this._ctxToMediaTime(this.audioCtx.currentTime)
    }
    set currentTime(t) {
        // Fire-and-forget — matches HTMLMediaElement semantics.
        this.seek(t)
    }

    get duration() {
        return this._duration || 0
    }
    set duration(_v) {
        // ignored — duration comes from the file
    }

    get paused() {
        return this._paused
    }

    get ended() {
        return this._ended
    }

    get readyState() {
        // Lie just enough for existing controls code: `readyState >= 1` means
        // metadata is available. We set this once the boot sequence has
        // computed duration + opened decoders.
        return this._ready ? 4 : 0
    }

    get volume() {
        return this._volume
    }
    set volume(v) {
        const clamped = Math.max(0, Math.min(1, v))
        this._volume = clamped
        if (this.audioGain) this.audioGain.gain.value = this._muted ? 0 : clamped
        this.dispatchEvent(new Event("volumechange"))
    }

    get muted() {
        return this._muted
    }
    set muted(m) {
        this._muted = !!m
        if (this.audioGain) this.audioGain.gain.value = this._muted ? 0 : this._volume
        this.dispatchEvent(new Event("volumechange"))
    }

    // Used by the player CSS / fullscreen helpers — they expect to call
    // `requestFullscreen` on a DOM element. The host receives the call.
    requestFullscreen(...args) {
        return this.host.requestFullscreen(...args)
    }

    async dispose() {
        if (this.disposed) return
        this.disposed = true
        if (this.rafId != null) cancelAnimationFrame(this.rafId)
        if (this.videoPumpAbort) this.videoPumpAbort()
        if (this.audioPumpAbort) this.audioPumpAbort()
        await Promise.allSettled([this.videoPumpDone, this.audioPumpDone].filter(Boolean))
        for (const f of this.videoFrameQueue) f.close()
        this.videoFrameQueue = []
        for (const s of this.liveAudioSources) {
            try {
                s.stop()
            } catch (_) {
                void _
            }
        }
        this.liveAudioSources.clear()
        try {
            this.videoDecoder?.close()
        } catch (_) {
            void _
        }
        try {
            await this.audioCtx.close()
        } catch (_) {
            void _
        }
        try {
            this.input?.dispose?.()
        } catch (_) {
            void _
        }
        if (this.canvas && this.canvas.parentNode) this.canvas.parentNode.removeChild(this.canvas)
    }
}

// Tiny abortable-wrapper: gives a `signal` object with a boolean `aborted`
// field that long async loops can poll. We don't use AbortController/AbortSignal
// because mediabunny's async iterators aren't AbortSignal-aware and we don't
// need true cancellation propagation — the gen check + `signal.aborted` poll
// is enough to break out of the loop within ~one packet.
function makeAbortable(fn) {
    const signal = { aborted: false }
    const promise = (async () => {
        try {
            await fn(signal)
        } catch (e) {
            if (!signal.aborted) console.warn("[player] pump threw", e)
        }
    })()
    return {
        promise,
        abort() {
            signal.aborted = true
        }
    }
}

function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms))
}

// Per-channel L/R gains for downmixing an `inChs`-channel WebCodecs AudioData
// frame to stereo. Channel order follows WAVE_FORMAT_EXTENSIBLE / WebCodecs
// convention: FL, FR, FC, LFE, BL, BR, SL, SR. Gains for the center / surround
// channels follow ITU-R BS.775-1 (0.707 = -3 dB) so dialogue (center) stays
// audible. LFE is dropped — no good way to fold subbass into stereo without
// surprising people on small speakers. Unknown layouts fall back to copying
// ch0→L and ch1→R; everything else is silenced.
const C707 = 0.707
function downmixGains(inChs, ch) {
    if (inChs === 1) return [1, 1] // mono → both
    if (inChs === 2) return ch === 0 ? [1, 0] : [0, 1]
    if (inChs === 6) {
        // 5.1: FL, FR, FC, LFE, BL, BR
        switch (ch) {
            case 0:
                return [1, 0]
            case 1:
                return [0, 1]
            case 2:
                return [C707, C707]
            case 3:
                return [0, 0]
            case 4:
                return [C707, 0]
            case 5:
                return [0, C707]
        }
    }
    if (inChs === 8) {
        // 7.1: FL, FR, FC, LFE, BL, BR, SL, SR
        switch (ch) {
            case 0:
                return [1, 0]
            case 1:
                return [0, 1]
            case 2:
                return [C707, C707]
            case 3:
                return [0, 0]
            case 4:
                return [C707, 0]
            case 5:
                return [0, C707]
            case 6:
                return [C707, 0]
            case 7:
                return [0, C707]
        }
    }
    // Unknown layout — take ch 0 and 1 as a best-effort L/R; drop the rest.
    if (ch === 0) return [1, 0]
    if (ch === 1) return [0, 1]
    return [0, 0]
}
