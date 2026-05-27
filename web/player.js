// Client-side WebCodecs player. Mediabunny demuxes the file over HTTP Range
// requests; WebCodecs decodes; the video frames go to a canvas, the audio
// frames are scheduled into the AudioContext clock, which is the master clock.
//
// Public entry point: `startPlayer({ host, manifest, ...callbacks })`.
// Returns a controller with play/pause/seek/dispose.

import { Input, UrlSource, ALL_FORMATS, EncodedPacketSink } from "/vendor/mediabunny.mjs"

// How many decoded video frames to keep queued ahead of the audio clock before
// we pause feeding the decoder. Keeps memory bounded on long fast scrubs.
const VIDEO_FRAME_QUEUE_TARGET = 24
// How far ahead (seconds) of `audioCtx.currentTime` we'll pre-schedule audio
// buffer sources. Larger = more resilient to main-thread jank but more pending
// state to tear down on seek.
const AUDIO_SCHEDULE_LOOKAHEAD_S = 0.5
// `requestAnimationFrame` cadence on the user's display is usually 60 Hz; the
// presentation loop runs every rAF and only draws when a frame is due.

export async function startPlayer({ host, manifest, startAt, onTimeUpdate, onDurationChange, onEnded, onError }) {
    const ctl = new PlayerController({ host, manifest, startAt, onTimeUpdate, onDurationChange, onEnded, onError })
    await ctl.boot()
    return ctl
}

class PlayerController extends EventTarget {
    constructor({ host, manifest, startAt, onTimeUpdate, onDurationChange, onEnded, onError }) {
        super()
        this.host = host
        this.manifest = manifest
        this.startAt = startAt || 0
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

        // WebCodecs decoders
        this.videoDecoder = null
        this.audioDecoder = null

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
        // Start suspended; we resume on first play() call. Some browsers reject
        // a resume() that hasn't been preceded by a user gesture; the controls
        // bar's play button is the gesture.
        await this.audioCtx.suspend().catch(() => {})

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
        this.audioTrack = await this.input.getPrimaryAudioTrack()

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
    }

    async _setupVideo() {
        const cfg = await this.videoTrack.getDecoderConfig()
        if (!cfg) {
            this.onError(`unknown video codec: ${await this.videoTrack.getCodec()}`)
            return
        }
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

        this.videoDecoder = new VideoDecoder({
            output: (frame) => this._onVideoFrame(frame),
            error: (e) => {
                console.warn("[player] video decoder error", e)
                this.onError(`video decoder error: ${e.message}`)
            }
        })
        this.videoDecoder.configure(cfg)

        this.videoSink = new EncodedPacketSink(this.videoTrack)
    }

    async _setupAudio() {
        const cfg = await this.audioTrack.getDecoderConfig()
        if (!cfg) {
            // No audio is still playable — just skip.
            console.warn("[player] no audio decoder config; muting audio")
            this.audioTrack = null
            return
        }
        const { supported } = await AudioDecoder.isConfigSupported(cfg)
        if (!supported) {
            console.warn("[player] unsupported audio codec; muting", cfg.codec)
            this.audioTrack = null
            return
        }

        this.audioDecoder = new AudioDecoder({
            output: (data) => this._onAudioFrame(data),
            error: (e) => console.warn("[player] audio decoder error", e)
        })
        this.audioDecoder.configure(cfg)

        this.audioSink = new EncodedPacketSink(this.audioTrack)
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

        // Flush decoders so subsequent decode() calls don't see stale state.
        if (this.videoDecoder?.state === "configured") await this.videoDecoder.flush().catch(() => {})
        if (this.audioDecoder?.state === "configured") await this.audioDecoder.flush().catch(() => {})

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
        if (!pkt) return
        // The clearing of stale frames is handled in _onVideoFrame: anything
        // whose timestamp is below startTime gets dropped silently.
        this._discardFramesBefore = startTime
        while (pkt && !signal.aborted && gen === this.gen) {
            // Backpressure: if the decoded queue is full and the audio clock
            // hasn't caught up, wait.
            while (this.videoFrameQueue.length >= VIDEO_FRAME_QUEUE_TARGET && !signal.aborted && gen === this.gen) {
                await sleep(16)
            }
            if (signal.aborted || gen !== this.gen) break
            try {
                this.videoDecoder.decode(pkt.toEncodedVideoChunk())
            } catch (e) {
                console.warn("[player] video decode threw", e)
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
        let pkt = await this.audioSink.getKeyPacket(startTime)
        if (!pkt) return
        // Audio doesn't have keyframes — every packet is independently
        // decodable — but mediabunny's getKeyPacket on an audio sink returns
        // the nearest preceding packet (== the first packet whose start <= t).
        // We may still get a few frames whose start is < startTime; the audio
        // scheduler skips ones that would land in the past.
        while (pkt && !signal.aborted && gen === this.gen) {
            // Backpressure: stay roughly `lookahead` ahead of the play head.
            const ahead = this.audioNextCtxTime - this.audioCtx.currentTime
            if (ahead > AUDIO_SCHEDULE_LOOKAHEAD_S) {
                await sleep(20)
                continue
            }
            try {
                this.audioDecoder.decode(pkt.toEncodedAudioChunk())
            } catch (e) {
                console.warn("[player] audio decode threw", e)
                break
            }
            pkt = await this.audioSink.getNextPacket(pkt)
        }
        if (!signal.aborted && gen === this.gen) {
            try {
                await this.audioDecoder.flush()
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

    _onAudioFrame(data) {
        if (this.disposed) {
            data.close()
            return
        }
        const tSec = data.timestamp / 1e6
        // If this frame would land entirely in the past relative to our seek
        // target, drop it.
        if (tSec + data.numberOfFrames / data.sampleRate < this.audioBaseMediaTime) {
            data.close()
            return
        }
        // Build an AudioBuffer and schedule it.
        const channels = data.numberOfChannels
        const frames = data.numberOfFrames
        const buf = this.audioCtx.createBuffer(channels, frames, data.sampleRate)
        const planar = new Float32Array(frames)
        for (let ch = 0; ch < channels; ch++) {
            data.copyTo(planar, { planeIndex: ch, format: "f32-planar" })
            buf.copyToChannel(planar, ch)
        }
        data.close()
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
        const mediaTime = this.getCurrentTime()

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

    async play() {
        if (this.disposed) return
        this._ended = false
        if (this.audioCtx.state === "suspended") {
            try {
                await this.audioCtx.resume()
            } catch (e) {
                console.warn("[player] audioCtx.resume rejected (likely no user gesture yet)", e)
            }
        }
        // Browsers gate AudioContext.resume() on a user gesture (autoplay
        // policy). If resume didn't actually take effect, stay paused and
        // let the user click play.
        if (this.audioCtx.state !== "running") {
            this._paused = true
            return
        }
        this._paused = false
        this.dispatchEvent(new Event("play"))
    }

    async pause() {
        if (this.disposed) return
        if (this.audioCtx.state === "running") await this.audioCtx.suspend()
        this._paused = true
        this.dispatchEvent(new Event("pause"))
    }

    async seek(t) {
        if (this.disposed) return
        const clamped = Math.max(0, Math.min(t, this._duration || t))
        await this._restartAtTime(clamped)
        this.onTimeUpdate(clamped)
        this.dispatchEvent(new Event("timeupdate"))
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
            this.audioDecoder?.close()
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
