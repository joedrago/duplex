import SwiftUI
import VLCUI

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

    @StateObject private var proxy = VLCVideoPlayer.Proxy()
    @StateObject private var session = PlayerSession()
    @EnvironmentObject private var nav: NavCoordinator

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
                    nextName: session.nextEntry?.name,
                    onContinue: {
                        if let next = session.nextEntry {
                            NSLog("[Duplex/Player] Continue pressed: from=%@ → name=%@ vpath=%@",
                                  vpath, next.name, next.vpath)
                            nav.path.removeLast()
                            nav.push(.player(vpath: next.vpath))
                        } else {
                            NSLog("[Duplex/Player] Continue pressed but nextEntry is nil; vpath=%@", vpath)
                        }
                    },
                    onDone: {
                        NSLog("[Duplex/Player] Done pressed; vpath=%@", vpath)
                        nav.path.removeLast()
                    }
                )
            case .failed(let reason):
                PlayerErrorCard(icon: "⚠️", title: "Couldn't play this file", detail: reason)
            case .playing:
                playerSurface
            }
        }
        .task { await session.start(client: client, vpath: vpath) }
        .onDisappear {
            osdHideTask?.cancel()
            session.teardown()
        }
        .onChange(of: session.remoteCommandTick) { _, _ in
            // Siri / Control Center / headphone button just fired — flash OSD.
            bumpOSD()
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
                    else { nav.path.removeLast() }
                }
            )
        )
        .onExitCommand {
            // Fires when picker focus has Menu pressed (RemoteInput is inactive then).
            if pickerOpen { pickerOpen = false }
            else { nav.path.removeLast() }
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack(alignment: .bottom) {
            VLCVideoPlayer { session.makeConfiguration(client: client, vpath: vpath) }
                .proxy(proxy)
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
                        session.handleTick(positionSeconds: posSec, totalSeconds: totalSec, info: info, vpath: vpath)
                    }
                }
                .ignoresSafeArea()

            if osdVisible && !pickerOpen {
                PlayerOSDBar(
                    title: DuplexFormat.leaf(of: vpath),
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
                        proxy.setSubtitleTrack(.absolute(idx))
                        session.currentSubtitleTrackIndex = idx
                        pickerOpen = false
                        bumpOSD()
                    },
                    onSelectAudio: { idx in
                        proxy.setAudioTrack(.absolute(idx))
                        session.currentAudioTrackIndex = idx
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
        if session.isPlaying { proxy.pause() } else { proxy.play() }
    }

    /// Begin a scrub. Fires the initial ±baseSeekStep immediately so a quick
    /// tap still produces a discrete jump, then starts an accelerating timer
    /// that runs as long as the user holds the arrow key.
    private func startScrub(_ direction: ScrubDirection) {
        scrubTimer?.invalidate()
        scrubTimer = nil

        // Immediate first jump.
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
    }

    private func applyScrub(direction: ScrubDirection, step: Int) {
        guard #available(tvOS 16.0, *) else { return }
        let d: Duration = .seconds(step)
        switch direction {
        case .forward:  proxy.jumpForward(d)
        case .backward: proxy.jumpBackward(d)
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
    private var lastHeartbeatTickSecond: Int = -1
    private let nowPlaying = NowPlayingController()
    private var attachedNowPlaying = false

    func makeConfiguration(client: DuplexClient, vpath: String) -> VLCVideoPlayer.Configuration {
        let raw = client.rawURL(path: vpath)
        var cfg = VLCVideoPlayer.Configuration(url: raw)
        cfg.autoPlay = true
        return cfg
    }

    func start(client: DuplexClient, vpath: String) async {
        guard case .idle = state else { return }
        NSLog("[Duplex/Player] start vpath=%@", vpath)
        state = .loading
        let next: NextResponse? = (try? await client.next(path: vpath)) ?? nil
        if let next {
            NSLog("[Duplex/Player] /api/next for=%@ → name=%@ vpath=%@", vpath, next.name, next.vpath)
        } else {
            NSLog("[Duplex/Player] /api/next for=%@ → none", vpath)
        }
        state = .playing
        self.nextEntry = next
    }

    func teardown() {
        if attachedNowPlaying {
            nowPlaying.detach()
            attachedNowPlaying = false
        }
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
        ingestTracks(info: info)
        switch state {
        case .opening, .buffering, .esAdded:
            break
        case .playing:
            isPlaying = true
            attachNowPlayingIfNeeded(proxy: proxy, vpath: vpath)
            applyDefaultsIfNeeded(info: info, proxy: proxy)
            if !didSeekToResume, let entry = ResumeStore.shared.get(vpath), entry.pos > 5 {
                didSeekToResume = true
                if #available(tvOS 16.0, *) {
                    proxy.setSeconds(.seconds(Int(entry.pos)))
                }
            } else {
                didSeekToResume = true
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
            self.state = .ended
        case .error:
            self.state = .failed("VLC reported playback error")
        @unknown default:
            break
        }
    }

    func handleTick(positionSeconds: Int, totalSeconds: Int, info: VLCVideoPlayer.PlaybackInformation, vpath: String) {
        if positionSeconds != self.positionSeconds || totalSeconds != self.durationSeconds {
            NSLog("[Duplex/Player/T] tick pos=%ds dur=%ds infoPos=%.3f",
                  positionSeconds, totalSeconds, Double(info.position))
        }
        self.positionSeconds = positionSeconds
        self.durationSeconds = totalSeconds
        ingestTracks(info: info)
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
        if audio != audioTracks { audioTracks = audio }
        if subs != subtitleTracks { subtitleTracks = subs }
        if info.currentAudioTrack.index != currentAudioTrackIndex {
            currentAudioTrackIndex = info.currentAudioTrack.index
        }
        if info.currentSubtitleTrack.index != currentSubtitleTrackIndex {
            currentSubtitleTrackIndex = info.currentSubtitleTrack.index
        }
    }

    /// Apply our default audio + subtitle preferences once, after the first
    /// .playing event. Subs default to off; audio defaults to the first
    /// English-language track if we can detect one, otherwise leave VLC's
    /// default selection alone.
    private func applyDefaultsIfNeeded(info: VLCVideoPlayer.PlaybackInformation, proxy: VLCVideoPlayer.Proxy) {
        guard !didApplyDefaults else { return }
        didApplyDefaults = true

        // 1. Subs off.
        proxy.setSubtitleTrack(.absolute(-1))
        currentSubtitleTrackIndex = -1

        // 2. English audio if available.
        let realAudio = info.audioTracks.filter { isRealTrack($0) }
        if let english = realAudio.first(where: { titleHintsEnglish($0.title) }) {
            proxy.setAudioTrack(.absolute(english.index))
            currentAudioTrackIndex = english.index
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
