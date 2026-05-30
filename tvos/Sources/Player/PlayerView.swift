import CoreText
import SwiftUI
import UIKit
import VLCUI

/// Registers the bundled `SubtitleFont.ttf` with CoreText and exposes its
/// PostScript name. tvOS ships only Apple's modern .SFUI font, which VLCKit's
/// freetype text renderer can't parse (FT error 3 / unknown file format), so
/// SRT/SubRip subtitles never paint until we hand the renderer a TTF it can
/// actually open. Registered process-scoped so `UIFont(name:size:)` resolves.
enum SubtitleFontRegistry {
    static let postScriptName: String? = registerAndDeriveName()

    private static func registerAndDeriveName() -> String? {
        guard let url = Bundle.main.url(forResource: "SubtitleFont", withExtension: "ttf") else {
            NSLog("[Duplex/SubtitleFont] bundled font not found")
            return nil
        }
        var err: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        if !ok, let e = err?.takeUnretainedValue() {
            NSLog("[Duplex/SubtitleFont] CTFontManagerRegisterFontsForURL failed: %@",
                  String(describing: e))
        }
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let desc = descs.first,
              let name = CTFontDescriptorCopyAttribute(desc, kCTFontNameAttribute) as? String else {
            NSLog("[Duplex/SubtitleFont] could not read PostScript name from %@", url.path)
            return nil
        }
        NSLog("[Duplex/SubtitleFont] registered psName=%@", name)
        return name
    }
}

/// Bridges VLC's internal logging into our `[Duplex/VLC]` NSLog stream so we
/// can debug subtitle / decoder / module-loading issues from the device console.
/// Filters to subtitle-relevant lines only — VLC at .info level is otherwise
/// extremely chatty.
final class DuplexVLCLogger: VLCVideoPlayerLogger {
    static let shared = DuplexVLCLogger()
    func vlcVideoPlayer(didLog message: String, at level: VLCVideoPlayer.LoggingLevel) {
        let lower = message.lowercased()
        let interesting = lower.contains("sub")
            || lower.contains("freetype")
            || lower.contains("quartz")
            || lower.contains("text-renderer")
            || lower.contains("font")
            || lower.contains("srt")
            || lower.contains("subrip")
            || lower.contains("decoder")
            || lower.contains("error")
            || lower.contains("warning")
        guard interesting else { return }
        NSLog("[Duplex/VLC] %@", message)
    }
}

/// VLCKit-backed player. Hands `/api/raw?path=…` straight to libVLC and lets
/// it handle demux/decode/audio/subs/HDR. We add a SwiftUI OSD on top because
/// VLCUI is just a rendering surface — there's no built-in chrome.
///
/// Remote bindings:
///   Menu                 → back to browse (NavigationStack pop)
///   Play/Pause or Select → toggle play/pause
///   ← / →                → seek ±10s
///   ↑                    → subtitle picker
///   ↓                    → audio track picker
///
/// OSD auto-hides 4 seconds after the last interaction.
struct PlayerView: View {
    let vpath: String
    /// Non-nil when this playback is part of a binge — finishing the video
    /// advances that binge's queue, and "next" comes from the queue rather
    /// than `/api/next`.
    let bingeId: String?

    @StateObject private var proxy = VLCVideoPlayer.Proxy()
    @StateObject private var session = PlayerSession()
    @EnvironmentObject private var nav: NavCoordinator
    @ObservedObject private var houseParty = HousePartyStore.shared
    @ObservedObject private var ext = ExtensionPreference.shared

    // House Party: announce (broadcast) this video to the party once it reaches
    // steady playback — this IS the "I started a video" broadcast. Skipped when
    // the playback was itself started by mirroring (the DJ already announced it).
    @State private var didAnnounce = false
    // Debounces the arrow-scrub broadcast. Holding an arrow arrives as a rapid
    // stream of press-repeats; we keep the mirror suppressed throughout and
    // broadcast ONE settled position when the stream stops.
    @State private var scrubBroadcastTask: Task<Void, Never>?
    // Throttles mirror-driven seeks so a slow-to-load target can't storm.
    @State private var lastMirrorSeekAt: Date = .distantPast

    @State private var osdVisible: Bool = true
    @State private var osdHideTask: Task<Void, Never>?
    @State private var pickerOpen: Bool = false
    @State private var pickerInitialColumn: PickerColumn = .subtitle

    // Hold-to-scrub state.
    @State private var scrubTimer: Timer?
    @State private var scrubStartedAt: Date?
    @State private var scrubDirection: ScrubDirection?

    private enum ScrubDirection { case forward, backward }

    private let client = DuplexClient()
    private let baseSeekStep = 10

    private var isPlayingState: Bool {
        if case .playing = session.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            DuplexColor.bg.ignoresSafeArea()
            switch session.state {
            case .idle, .loading:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(DuplexColor.accent)
            case .ended:
                EndOfVideoCard(
                    nextName: nextDisplayName,
                    onContinue: { playNext() },
                    onDone: {
                        NSLog("[Duplex/Player] Done pressed; vpath=%@", vpath)
                        backOut()
                    }
                )
            case .failed(let reason):
                PlayerErrorCard(icon: "⚠️", title: "Couldn't play this file", detail: reason)
            case .playing:
                playerSurface
            }
        }
        .task {
            NSLog("[Duplex/Player/V] appear vpath=%@ bingeId=%@ stackDepth=%d", vpath, bingeId ?? "(none)", nav.path.count)
            // A user-initiated start (not a mirror-start, which the store flags
            // via suppressAnnounceVpath) opens the local-authority window
            // immediately, so a stale `idle` poll can't pop us before our
            // announce propagates.
            if houseParty.joined, houseParty.suppressAnnounceVpath != vpath {
                houseParty.markLocalAction()
            }
            await session.start(client: client, vpath: vpath, bingeId: bingeId)
        }
        .onDisappear {
            NSLog("[Duplex/Player/V] disappear vpath=%@ stackDepth=%d state=%@", vpath, nav.path.count, String(describing: session.state))
            osdHideTask?.cancel()
            scrubBroadcastTask?.cancel()
            // The reliable back-out signal: the player always gets onDisappear,
            // whereas the Menu button isn't always delivered to our input view.
            // Leaving idles the party for the room — UNLESS the store itself is
            // changing the player (mirror swap / idle-pop / Continue), which also
            // fires onDisappear.
            if houseParty.joined, !houseParty.isSelfNavigating {
                houseParty.clear()
            }
            // Back-out path for the binge pop rule: if the user leaves with
            // <5% remaining, advance the binge here (idempotent with the
            // natural-end pop). Must run before stop() while position is valid.
            session.maybeAdvanceBinge(vpath: vpath, finished: false)
            // Without an explicit stop, the underlying VLCMediaPlayer keeps
            // decoding (and the audio session keeps the audio audible) after
            // the user pops back to the browse/home routes.
            proxy.stop()
            session.teardown()
        }
        .onChange(of: session.remoteCommandTick) { _, _ in
            // Siri / Control Center / headphone button just fired — flash OSD.
            bumpOSD()
        }
        .onChange(of: houseParty.latest) { _, _ in
            // Mirror (server → local) for the video we're already playing.
            applyHousePartyMirror()
        }
        .onChange(of: session.positionSeconds) { _, _ in
            // Drives only the one-shot start announce. (Broadcasts come solely
            // from explicit input handlers — never from observing state changes.)
            announceToHousePartyIfNeeded()
        }
        .navigationBarHidden(true)
        .background(
            // UIKit bridge captures press-began / press-ended so we can detect
            // arrow-key holds for accelerating scrub. Active only when no
            // picker overlay is up — the picker's SwiftUI Buttons handle
            // input via the normal focus engine.
            PlayerRemoteInput(
                // Only intercept presses on the live player surface — leaving
                // it active during .ended would steal focus from the
                // EndOfVideoCard buttons (Continue / Done).
                isActive: !pickerOpen && isPlayingState,
                onLeftBegan: { startScrub(.backward) },
                onLeftEnded: { endScrub() },
                onRightBegan: { startScrub(.forward) },
                onRightEnded: { endScrub() },
                onUpTap: {
                    pickerInitialColumn = .subtitle
                    pickerOpen = true
                    osdHideTask?.cancel()
                },
                onDownTap: {
                    pickerInitialColumn = .audio
                    pickerOpen = true
                    osdHideTask?.cancel()
                },
                onSelectTap: { togglePlay(); bumpOSD() },
                onPlayPauseTap: { togglePlay(); bumpOSD() },
                onMenuTap: {
                    if pickerOpen { pickerOpen = false }
                    else { backOut() }
                }
            )
        )
        .onExitCommand {
            // Fires when picker focus has Menu pressed (RemoteInput is inactive then).
            if pickerOpen { pickerOpen = false }
            else { backOut() }
        }
    }

    // MARK: - Continue / next-up

    /// What the end-of-video card offers next. For a binge, that's the queue's
    /// current front (the just-finished video was already popped in the
    /// `.ended` handler); otherwise it's the `/api/next` sibling.
    private var nextDisplayName: String? {
        if let bid = bingeId {
            return BingeStore.shared.binge(id: bid)?.front.map { DuplexFormat.displayFileLeaf(of: $0) }
        }
        return session.nextEntry.map { DuplexFormat.displayFileName($0.name) }
    }

    /// Play whatever `nextDisplayName` describes, preserving binge binding.
    private func playNext() {
        let target: (vpath: String, bingeId: String?)?
        if let bid = bingeId {
            target = BingeStore.shared.binge(id: bid)?.front.map { ($0, bid) }
        } else if let next = session.nextEntry {
            target = (next.vpath, nil)
        } else {
            target = nil
        }
        guard let t = target, !nav.path.isEmpty else {
            NSLog("[Duplex/Player] Continue pressed but no next; vpath=%@", vpath)
            return
        }
        // Replace the current player on the stack ATOMICALLY rather than
        // removeLast()+push(). The two-step form races inside NavigationStack —
        // it begins tearing the stack down to root before the push lands, so
        // the next player mounts onto a half-popped stack, VLC gets stopped
        // before it can play (instant .ended at pos 0), and the eventual return
        // to Home renders black. A single assignment swaps the top destination
        // cleanly; .id(vpath) in makeView still forces a fresh PlayerView.
        NSLog("[Duplex/Player] Continue → vpath=%@ bingeId=%@", t.vpath, t.bingeId ?? "(none)")
        // Programmatic player swap — not a user back-out — so onDisappear of the
        // current player must not clear the party.
        houseParty.markSelfNav()
        nav.path[nav.path.count - 1] = .player(vpath: t.vpath, bingeId: t.bingeId)
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack(alignment: .bottom) {
            VLCVideoPlayer { session.makeConfiguration(client: client, vpath: vpath) }
                .proxy(proxy)
                .logger(DuplexVLCLogger.shared, level: .info)
                .onStateUpdated { state, info in
                    Task { @MainActor in session.handleState(state, info: info, proxy: proxy, vpath: vpath) }
                }
                .onSecondsUpdated { duration, info in
                    let totalSec = info.length / 1000
                    let timeSec = Int(duration.components.seconds)
                    // Observed on tvOS: `player.time` (which Duration is derived
                    // from here) is stuck at 0 for some HTTP-streamed mp4s even
                    // though playback advances. `info.position` (Float 0..1 from
                    // VLCKit) tracks correctly, so prefer it whenever we have a
                    // known media length.
                    let posSec: Int
                    if totalSec > 0 && info.position > 0 {
                        posSec = Int((Double(info.position) * Double(totalSec)).rounded())
                    } else {
                        posSec = timeSec
                    }
                    Task { @MainActor in
                        session.handleTick(positionSeconds: posSec, totalSeconds: totalSec, info: info, proxy: proxy, vpath: vpath)
                    }
                }
                .ignoresSafeArea()

            if osdVisible && !pickerOpen {
                PlayerOSDBar(
                    title: DuplexFormat.displayFileLeaf(of: vpath),
                    isPlaying: session.isPlaying,
                    positionSeconds: session.positionSeconds,
                    durationSeconds: session.durationSeconds
                )
                .transition(.opacity)
                .padding(.horizontal, 60)
                .padding(.bottom, 70)
            }

            if pickerOpen {
                PlayerDualPicker(
                    subtitleOptions: subtitleOptions,
                    audioOptions: audioOptions,
                    currentSubtitleIndex: session.currentSubtitleTrackIndex,
                    currentAudioIndex: session.currentAudioTrackIndex,
                    initialColumn: pickerInitialColumn,
                    onSelectSubtitle: { idx in
                        NSLog("[Duplex/Player] setSubtitleTrack(absolute: %d)", idx)
                        proxy.setSubtitleTrack(.absolute(idx))
                        session.currentSubtitleTrackIndex = idx
                        TrackPrefsStore.shared.setSubtitle(vpath: vpath, index: idx)
                        pickerOpen = false
                        bumpOSD()
                    },
                    onSelectAudio: { idx in
                        NSLog("[Duplex/Player] setAudioTrack(absolute: %d)", idx)
                        proxy.setAudioTrack(.absolute(idx))
                        session.currentAudioTrackIndex = idx
                        TrackPrefsStore.shared.setAudio(vpath: vpath, index: idx)
                        pickerOpen = false
                        bumpOSD()
                    },
                    onClose: { pickerOpen = false }
                )
            }
        }
        .animation(.easeOut(duration: 0.18), value: osdVisible)
        .animation(.easeOut(duration: 0.18), value: pickerOpen)
        .onAppear { bumpOSD() }
    }

    private var audioOptions: [PlayerTrackOption] {
        // Preserve the order VLC reports; show titles raw.
        session.audioTracks.map { track in
            PlayerTrackOption(
                index: track.index,
                label: track.title.isEmpty ? "Track \(track.index)" : track.title
            )
        }
    }

    private var subtitleOptions: [PlayerTrackOption] {
        // "Off" is the only synthesized entry. Otherwise preserve VLC's order
        // and raw titles.
        var opts: [PlayerTrackOption] = [PlayerTrackOption(index: -1, label: "Off")]
        opts.append(contentsOf: session.subtitleTracks.map { track in
            PlayerTrackOption(
                index: track.index,
                label: track.title.isEmpty ? "Track \(track.index)" : track.title
            )
        })
        return opts
    }

    // MARK: - Input handling

    private func togglePlay() {
        let willPlay = !session.isPlaying
        if session.isPlaying { proxy.pause() } else { proxy.play() }
        // Explicit user gesture → broadcast. No-op when not joined.
        houseParty.broadcast(vpath: vpath, duration: Double(session.durationSeconds),
                             position: Double(session.positionSeconds), playing: willPlay)
    }

    /// Leave the player. The party clear happens in `onDisappear` (the reliable
    /// signal), so this just pops.
    private func backOut() {
        nav.path.removeLast()
    }

    // MARK: - House Party sync (server → local; never broadcasts)

    /// Conform the live player to the party state for the video we're already
    /// playing. This is the ONLY code that reacts to the server, and it only ever
    /// drives the proxy — it never broadcasts, so it cannot echo.
    private func applyHousePartyMirror() {
        // `mirrorSuppressed`: we broadcast a local action moments ago; ignore the
        // poll until the round-trip reflects it, so we don't undo ourselves.
        guard houseParty.joined, !houseParty.mirrorSuppressed, isPlayingState,
              let s = houseParty.latest, s.active, s.vpath == vpath else { return }
        if s.playing && !session.isPlaying {
            proxy.play()
        } else if !s.playing && session.isPlaying {
            proxy.pause()
        }
        // 2s tolerance: a seek causes a brief buffer stall that leaves us ~1s
        // behind, so a 1s threshold re-triggers itself; 2s lets steady-state
        // jitter settle while still snapping on a real DJ seek. The 2.5s cooldown
        // stops a still-unreachable target from storming seeks.
        if abs(s.position - Double(session.positionSeconds)) > 2.0,
           Date().timeIntervalSince(lastMirrorSeekAt) > 2.5,
           #available(tvOS 16.0, *) {
            NSLog("[Duplex/HouseParty] sync seek %d → %.1f", session.positionSeconds, s.position)
            proxy.setSeconds(.seconds(Int(s.position)))
            lastMirrorSeekAt = Date()
            // The party just moved our position — flash the OSD so it's legible.
            bumpOSD()
        }
    }

    /// Announce this video to the party once it's playing with a known duration —
    /// unless this playback was started by mirroring, in which case the DJ
    /// already announced it (the store flagged it via `suppressAnnounceVpath`).
    private func announceToHousePartyIfNeeded() {
        guard houseParty.joined, !didAnnounce,
              session.durationSeconds > 0, session.isPlaying else { return }
        didAnnounce = true
        if houseParty.suppressAnnounceVpath == vpath {
            houseParty.suppressAnnounceVpath = nil
            return
        }
        houseParty.broadcast(
            vpath: vpath,
            duration: Double(session.durationSeconds),
            position: Double(session.positionSeconds),
            playing: true
        )
    }

    /// Begin a scrub. Fires the initial ±baseSeekStep immediately so a quick
    /// tap still produces a discrete jump, then starts an accelerating timer
    /// that runs as long as the user holds the arrow key.
    private func startScrub(_ direction: ScrubDirection) {
        scrubTimer?.invalidate()
        scrubTimer = nil

        applyScrub(direction: direction, step: baseSeekStep)
        bumpOSD()

        scrubStartedAt = Date()
        scrubDirection = direction
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in
                guard let started = scrubStartedAt, scrubDirection == direction else { return }
                let elapsed = Date().timeIntervalSince(started)
                let step = stepForHoldElapsed(elapsed)
                applyScrub(direction: direction, step: step)
                bumpOSD()
            }
        }
        scrubTimer = timer
    }

    private func endScrub() {
        scrubTimer?.invalidate()
        scrubTimer = nil
        scrubStartedAt = nil
        scrubDirection = nil
        scheduleScrubBroadcast()
    }

    private func applyScrub(direction: ScrubDirection, step: Int) {
        // Keep the mirror suppressed for the whole scrub so it never fights us
        // between press-repeats, and (re)arm the debounced broadcast.
        houseParty.markLocalAction()
        scheduleScrubBroadcast()
        guard #available(tvOS 16.0, *) else { return }
        let d: Duration = .seconds(step)
        switch direction {
        case .forward:  proxy.jumpForward(d)
        case .backward: proxy.jumpBackward(d)
        }
    }

    /// Broadcast the scrub destination once the stream of jumps stops. Debounced
    /// ~0.6s so a held arrow (many press-repeats) yields ONE POST, with VLC's
    /// settled position rather than a mid-seek readback.
    private func scheduleScrubBroadcast() {
        scrubBroadcastTask?.cancel()
        scrubBroadcastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, houseParty.joined,
                  nav.currentPlayerVpath == vpath else { return }
            houseParty.broadcast(vpath: vpath, duration: Double(session.durationSeconds),
                                 position: Double(session.positionSeconds), playing: session.isPlaying)
        }
    }

    /// Accelerating-scrub step size as a function of how long the arrow key
    /// has been held. Each tick of the hold-timer fires every 0.4s, so this
    /// curve is "per-tick" — the effective rate is `step / 0.4s`.
    ///
    ///   <1s   : 10s/step  →  25 s/sec
    ///   <2.5s : 30s/step  →  75 s/sec
    ///   <5s   : 60s/step  →  150 s/sec  (2.5 min/sec)
    ///   <8s   : 180s/step →  450 s/sec  (7.5 min/sec)
    ///   ≥8s   : 600s/step →  1500 s/sec (25 min/sec)
    private func stepForHoldElapsed(_ elapsed: TimeInterval) -> Int {
        switch elapsed {
        case ..<1.0: return 10
        case ..<2.5: return 30
        case ..<5.0: return 60
        case ..<8.0: return 180
        default:     return 600
        }
    }

    private func bumpOSD() {
        osdVisible = true
        osdHideTask?.cancel()
        osdHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { osdVisible = false }
        }
    }
}

// MARK: - OSD bar

private struct PlayerOSDBar: View {
    let title: String
    let isPlaying: Bool
    let positionSeconds: Int
    let durationSeconds: Int

    var body: some View {
        HStack(spacing: 24) {
            Text(isPlaying ? "▶" : "⏸")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(DuplexColor.fg)
                .frame(width: 48)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DuplexColor.fg)
                    .lineLimit(1)
                progressBar
                HStack {
                    Text(DuplexFormat.time(Double(positionSeconds)))
                        .font(.system(size: 18, weight: .regular).monospacedDigit())
                        .foregroundStyle(DuplexColor.muted)
                    Spacer()
                    Text(DuplexFormat.time(Double(durationSeconds)))
                        .font(.system(size: 18, weight: .regular).monospacedDigit())
                        .foregroundStyle(DuplexColor.muted)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(DuplexColor.panel.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DuplexMetric.panelRadius)
                .stroke(DuplexColor.border, lineWidth: 1)
        )
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DuplexColor.border)
                Capsule()
                    .fill(DuplexColor.accent)
                    .frame(width: geo.size.width * progressFraction)
            }
        }
        .frame(height: 6)
    }

    private var progressFraction: CGFloat {
        guard durationSeconds > 0 else { return 0 }
        return CGFloat(min(positionSeconds, durationSeconds)) / CGFloat(durationSeconds)
    }
}

// MARK: - Track picker

struct PlayerTrackOption: Identifiable, Hashable {
    let index: Int
    let label: String
    var id: Int { index }
}

enum PickerColumn: Hashable { case subtitle, audio }

private enum PickerFocus: Hashable {
    case sub(Int)
    case audio(Int)
}

/// Dual-column picker — subtitles left, audio right. Built on `WrapColumns`
/// so up/down wraps inside a column and left/right crosses to the same row
/// index in the sibling column. Menu closes the picker.
private struct PlayerDualPicker: View {
    let subtitleOptions: [PlayerTrackOption]
    let audioOptions: [PlayerTrackOption]
    let currentSubtitleIndex: Int
    let currentAudioIndex: Int
    let initialColumn: PickerColumn
    let onSelectSubtitle: (Int) -> Void
    let onSelectAudio: (Int) -> Void
    let onClose: () -> Void

    @State private var focus: PickerFocus?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            WrapColumns(
                columns: focusColumns,
                current: $focus,
                onActivate: handleActivate,
                onMenuTap: onClose
            ) {
                HStack(alignment: .top, spacing: DuplexMetric.columnGap) {
                    pickerColumn(
                        title: "Subtitles",
                        options: subtitleOptions,
                        currentIndex: currentSubtitleIndex,
                        makeKey: { PickerFocus.sub($0.index) }
                    )
                    pickerColumn(
                        title: "Audio",
                        options: audioOptions,
                        currentIndex: currentAudioIndex,
                        makeKey: { PickerFocus.audio($0.index) }
                    )
                }
                .frame(maxWidth: 1080, maxHeight: 640)
                .padding(.horizontal, 40)
            }
        }
        .onAppear { focus = makeInitialFocus() }
    }

    private var focusColumns: [[PickerFocus]] {
        [
            subtitleOptions.map { PickerFocus.sub($0.index) },
            audioOptions.map    { PickerFocus.audio($0.index) },
        ]
    }

    private func handleActivate(_ key: PickerFocus) {
        switch key {
        case .sub(let i):   onSelectSubtitle(i)
        case .audio(let i): onSelectAudio(i)
        }
    }

    @ViewBuilder
    private func pickerColumn(
        title: String,
        options: [PlayerTrackOption],
        currentIndex: Int,
        makeKey: @escaping (PlayerTrackOption) -> PickerFocus
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 18, weight: .semibold))
                .kerning(1.5)
                .foregroundStyle(DuplexColor.muted)
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 12)
            Rectangle().fill(DuplexColor.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(options) { opt in
                            let key = makeKey(opt)
                            GridEntryRow(
                                icon: opt.index == currentIndex ? "✓" : " ",
                                title: opt.label,
                                subtitle: nil,
                                meta: nil,
                                isFocused: focus == key
                            )
                            .id(key)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: focus) { _, new in
                    guard let new, options.contains(where: { makeKey($0) == new }) else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: 520, maxHeight: 600)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DuplexMetric.panelRadius)
                .stroke(DuplexColor.border, lineWidth: 1)
        )
    }

    private func makeInitialFocus() -> PickerFocus {
        switch initialColumn {
        case .subtitle:
            let idx = subtitleOptions.contains(where: { $0.index == currentSubtitleIndex })
                ? currentSubtitleIndex
                : (subtitleOptions.first?.index ?? -1)
            return .sub(idx)
        case .audio:
            let idx = audioOptions.contains(where: { $0.index == currentAudioIndex })
                ? currentAudioIndex
                : (audioOptions.first?.index ?? 0)
            return .audio(idx)
        }
    }
}

// MARK: - Session state

@MainActor
final class PlayerSession: ObservableObject {
    enum State {
        case idle, loading, playing, ended, failed(String)
    }

    @Published var state: State = .idle
    @Published var nextEntry: NextResponse?
    /// Set when playback is bound to a binge — see `maybeAdvanceBinge`.
    private(set) var bingeId: String?
    @Published var isPlaying: Bool = false
    @Published var positionSeconds: Int = 0
    @Published var durationSeconds: Int = 0
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var currentAudioTrackIndex: Int = 0
    @Published var currentSubtitleTrackIndex: Int = -1
    /// Bumps each time a remote command (Siri / Control Center) fires, so
    /// PlayerView can flash the OSD in response.
    @Published var remoteCommandTick: Int = 0

    private var didSeekToResume = false
    private var didApplyDefaults = false
    private var didApplySavedSub = false
    private var didAttachSidecars = false
    private var sidecarSubURLs: [(idx: Int, lang: String?, url: URL)] = []
    private var lastHeartbeatTickSecond: Int = -1
    private let nowPlaying = NowPlayingController()
    private var attachedNowPlaying = false

    func makeConfiguration(client: DuplexClient, vpath: String) -> VLCVideoPlayer.Configuration {
        let raw = client.rawURL(path: vpath)
        var cfg = VLCVideoPlayer.Configuration(url: raw)
        cfg.autoPlay = true
        // VLCUI's setConfigurationValues calls setSubtitleFont(...) at startup
        // with the configuration's font. We have to plant our bundled TTF
        // here, otherwise the default (UIFont.systemFont → ".SFUI-Regular")
        // wins and VLCKit's freetype renderer fails to load it on tvOS.
        if let psName = SubtitleFontRegistry.postScriptName,
           let uifont = UIFont(name: psName, size: 22) {
            cfg.subtitleFont = .absolute(uifont)
        }
        // Per VLCUI: subtitle size magnitudes are inverted — larger value
        // means smaller glyphs. VLCKit's default paints text enormous on
        // tvOS; ~40 lands at a TV-readable size.
        cfg.subtitleSize = .absolute(24)
        // Warm yellow, matching the `.cue-overlay` color in web/style.css
        // (#f5e6a8) so the platforms stay visually consistent.
        cfg.subtitleColor = .absolute(UIColor(red: 245.0/255.0, green: 230.0/255.0, blue: 168.0/255.0, alpha: 1.0))
        return cfg
    }

    func start(client: DuplexClient, vpath: String, bingeId: String? = nil) async {
        guard case .idle = state else { return }
        self.bingeId = bingeId
        NSLog("[Duplex/Player] start vpath=%@ bingeId=%@", vpath, bingeId ?? "(none)")
        state = .loading
        async let nextTask:     NextResponse? = (try? await client.next(path: vpath)) ?? nil
        async let manifestTask: Manifest?     = (try? await client.manifest(path: vpath)) ?? nil
        let next     = await nextTask
        let manifest = await manifestTask

        if let next {
            NSLog("[Duplex/Player] /api/next for=%@ → name=%@ vpath=%@", vpath, next.name, next.vpath)
        } else {
            NSLog("[Duplex/Player] /api/next for=%@ → none", vpath)
        }

        // Capture sidecar subtitle URLs so we can hand them to VLC as playback
        // children once the media is open. Without this, .srt/.vtt files next
        // to the video never appear in the subtitle picker.
        let sidecars = manifest?.sidecars ?? []
        self.sidecarSubURLs = sidecars.map { sc in
            (idx: sc.index, lang: sc.language, url: client.sidecarURL(path: vpath, index: sc.index))
        }
        NSLog("[Duplex/Player] manifest sidecars=%d", sidecars.count)

        state = .playing
        self.nextEntry = next
    }

    /// Add the manifest's sidecar subtitle files to VLC as playback children so
    /// they appear in the picker. Idempotent — runs once after VLC reports
    /// `.playing`.
    ///
    /// `enforce: false` — we do NOT auto-activate any sidecar. The default is
    /// "no subtitles" (see `applySavedSubIfPossible`); a sidecar only turns on
    /// when the user picks it, or when their saved preference points at it.
    /// (Enforcing the first slave used to silently force subs on whenever a file
    /// had a sidecar.)
    func attachSidecarsIfNeeded(proxy: VLCVideoPlayer.Proxy) {
        guard !didAttachSidecars else { return }
        didAttachSidecars = true
        for sc in sidecarSubURLs {
            NSLog("[Duplex/Player] addPlaybackChild sub idx=%d lang=%@ url=%@",
                  sc.idx, sc.lang ?? "?", sc.url.absoluteString)
            proxy.addPlaybackChild(.init(url: sc.url, type: .subtitle, enforce: false))
        }
    }

    func teardown() {
        if attachedNowPlaying {
            nowPlaying.detach()
            attachedNowPlaying = false
        }
    }

    /// Advance the bound binge past `vpath` when the video is effectively done.
    /// `finished` is true on a natural end; on back-out we apply the
    /// "<5% remaining" rule against the last known position. No-op when this
    /// playback isn't bound to a binge. `popFrontIfMatches` is idempotent — it
    /// only pops while `vpath` is still the queue's front — so the natural-end
    /// and back-out callers can't double-pop.
    func maybeAdvanceBinge(vpath: String, finished: Bool) {
        guard let bid = bingeId else { return }
        let watchedEnough = finished ||
            (durationSeconds > 0 && Double(positionSeconds) >= Double(durationSeconds) * 0.95)
        guard watchedEnough else { return }
        BingeStore.shared.popFrontIfMatches(id: bid, vpath: vpath)
    }

    /// Attach Siri / Control Center integration. Idempotent.
    func attachNowPlayingIfNeeded(proxy: VLCVideoPlayer.Proxy, vpath: String) {
        guard !attachedNowPlaying else { return }
        nowPlaying.attach(proxy: proxy, session: self, vpath: vpath)
        nowPlaying.onRemoteCommand = { [weak self] in
            self?.remoteCommandTick &+= 1
        }
        attachedNowPlaying = true
    }

    func handleState(_ state: VLCVideoPlayer.State, info: VLCVideoPlayer.PlaybackInformation, proxy: VLCVideoPlayer.Proxy, vpath: String) {
        NSLog("[Duplex/Player/S] vpath=%@ vlcState=%@ pos=%.3f", vpath, String(describing: state), Double(info.position))
        ingestTracks(info: info)
        switch state {
        case .opening, .buffering, .esAdded:
            break
        case .playing:
            isPlaying = true
            attachNowPlayingIfNeeded(proxy: proxy, vpath: vpath)
            attachSidecarsIfNeeded(proxy: proxy)
            applyDefaultsIfNeeded(info: info, proxy: proxy, vpath: vpath)
            if !didSeekToResume {
                didSeekToResume = true
                // In House Party, position is governed by the party, not the
                // local resume point — skip the resume-seek so it doesn't fight
                // the mirror, and so the DJ's announce reflects a clean start
                // rather than a stale resume position captured before the seek.
                if !HousePartyStore.shared.joined,
                   let entry = ResumeStore.shared.get(vpath), entry.pos > 5,
                   #available(tvOS 16.0, *) {
                    proxy.setSeconds(.seconds(Int(entry.pos)))
                }
            }
        case .paused:
            isPlaying = false
        case .stopped:
            isPlaying = false
        case .ended:
            NSLog("[Duplex/Player] state=ended vpath=%@ nextEntryVpath=%@",
                  vpath, nextEntry?.vpath ?? "(nil)")
            isPlaying = false
            ResumeStore.shared.remove(vpath)
            // Natural end ⇒ finished ⇒ advance the binge before we render the
            // end card, so "next" reflects the popped queue.
            maybeAdvanceBinge(vpath: vpath, finished: true)
            self.state = .ended
        case .error:
            self.state = .failed("VLC reported playback error")
        @unknown default:
            break
        }
    }

    func handleTick(positionSeconds: Int, totalSeconds: Int, info: VLCVideoPlayer.PlaybackInformation, proxy: VLCVideoPlayer.Proxy, vpath: String) {
        if positionSeconds != self.positionSeconds || totalSeconds != self.durationSeconds {
            NSLog("[Duplex/Player/T] tick pos=%ds dur=%ds infoPos=%.3f",
                  positionSeconds, totalSeconds, Double(info.position))
        }
        self.positionSeconds = positionSeconds
        self.durationSeconds = totalSeconds
        ingestTracks(info: info)
        applySavedSubIfPossible(proxy: proxy, vpath: vpath)
        if attachedNowPlaying {
            nowPlaying.updateNowPlayingInfo(
                positionSeconds: positionSeconds,
                durationSeconds: totalSeconds,
                isPlaying: isPlaying
            )
        }
        if positionSeconds > 0,
           positionSeconds % 5 == 0,
           positionSeconds != lastHeartbeatTickSecond {
            lastHeartbeatTickSecond = positionSeconds
            ResumeStore.shared.update(
                vpath: vpath,
                pos: Double(positionSeconds),
                dur: Double(totalSeconds)
            )
        }
    }

    /// Drops "Disable" entries that VLCKit injects (negative-indexed sentinels).
    private func ingestTracks(info: VLCVideoPlayer.PlaybackInformation) {
        let audio = info.audioTracks.filter { isRealTrack($0) }
        let subs = info.subtitleTracks.filter { isRealTrack($0) }
        if audio != audioTracks {
            audioTracks = audio
            NSLog("[Duplex/Player] audio tracks=%d: %@",
                  audio.count, audio.map { "[\($0.index):\($0.title)]" }.joined(separator: " "))
        }
        if subs != subtitleTracks {
            subtitleTracks = subs
            NSLog("[Duplex/Player] sub tracks=%d: %@",
                  subs.count, subs.map { "[\($0.index):\($0.title)]" }.joined(separator: " "))
        }
        if info.currentAudioTrack.index != currentAudioTrackIndex {
            currentAudioTrackIndex = info.currentAudioTrack.index
        }
        if info.currentSubtitleTrack.index != currentSubtitleTrackIndex {
            NSLog("[Duplex/Player] currentSub changed %d → %d",
                  currentSubtitleTrackIndex, info.currentSubtitleTrack.index)
            currentSubtitleTrackIndex = info.currentSubtitleTrack.index
        }
    }

    /// Apply audio defaults once, after the first .playing event. Subtitle
    /// pref is handled separately via `applySavedSubIfPossible` because
    /// sidecar tracks load asynchronously — they aren't in `info.subtitleTracks`
    /// at the moment of the first .playing event.
    private func applyDefaultsIfNeeded(info: VLCVideoPlayer.PlaybackInformation, proxy: VLCVideoPlayer.Proxy, vpath: String) {
        guard !didApplyDefaults else { return }
        didApplyDefaults = true

        let saved = TrackPrefsStore.shared.get(vpath)
        let realAudio = info.audioTracks.filter { isRealTrack($0) }

        // Audio: saved pref wins; otherwise prefer first English-language
        // track; otherwise leave VLC's default alone.
        if let savedAudio = saved?.audio,
           realAudio.contains(where: { $0.index == savedAudio }) {
            proxy.setAudioTrack(.absolute(savedAudio))
            currentAudioTrackIndex = savedAudio
        } else if let english = realAudio.first(where: { titleHintsEnglish($0.title) }) {
            proxy.setAudioTrack(.absolute(english.index))
            currentAudioTrackIndex = english.index
        }
    }

    /// Apply the saved subtitle pref once it's actually available. Sidecars
    /// are added as VLC playback children after .playing fires, so they show
    /// up in `subtitleTracks` a few ticks later. This is called from
    /// `ingestTracks` whenever the track list updates.
    private func applySavedSubIfPossible(proxy: VLCVideoPlayer.Proxy, vpath: String) {
        guard !didApplySavedSub else { return }
        guard let savedSub = TrackPrefsStore.shared.get(vpath)?.sub else {
            // No saved preference → default to None (off). Without explicitly
            // selecting -1, VLC auto-enables an embedded/default subtitle track.
            NSLog("[Duplex/Player] no saved sub pref → default None")
            proxy.setSubtitleTrack(.absolute(-1))
            currentSubtitleTrackIndex = -1
            didApplySavedSub = true
            return
        }
        if savedSub == -1 || subtitleTracks.contains(where: { $0.index == savedSub }) {
            NSLog("[Duplex/Player] apply saved sub idx=%d", savedSub)
            proxy.setSubtitleTrack(.absolute(savedSub))
            currentSubtitleTrackIndex = savedSub
            didApplySavedSub = true
        }
    }
}

// MARK: - Track helpers

private func isRealTrack(_ track: MediaTrack) -> Bool {
    if track.index < 0 { return false }
    let t = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t == "disable" || t == "disabled" { return false }
    return true
}

/// Try to surface just the human-meaningful name. VLC titles often look like
/// `"GuiVGA - [Portuguese]"` (codec/scrambled prefix + bracketed language).
/// Prefer the bracketed segment; otherwise return the trimmed original.
private func prettyTrackTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if let openIdx = trimmed.firstIndex(of: "["),
       let closeIdx = trimmed[openIdx...].firstIndex(of: "]"),
       openIdx < closeIdx {
        let inside = trimmed[trimmed.index(after: openIdx)..<closeIdx]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !inside.isEmpty { return inside }
    }
    return trimmed
}

private func titleHintsEnglish(_ raw: String) -> Bool {
    let title = (prettyTrackTitle(raw) ?? raw).lowercased()
    if title == "en" || title == "eng" || title == "english" { return true }
    if title.contains("english") { return true }
    // Match common language-tag suffixes: " en", "[en]", "(eng)", etc.
    let separators = CharacterSet(charactersIn: " ,;[](){}/-_")
    let tokens = title.unicodeScalars
        .split(whereSeparator: { separators.contains($0) })
        .map { String($0) }
    return tokens.contains("en") || tokens.contains("eng")
}
