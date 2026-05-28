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

    private let client = DuplexClient()
    private let seekStep = 10

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
                            nav.path.removeLast()
                            nav.push(.player(vpath: next.vpath))
                        }
                    },
                    onDone: { nav.path.removeLast() }
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
        .navigationBarHidden(true)
        // Stop being focusable while the picker is open, otherwise the focus
        // engine snaps to the player surface as soon as the user tries to
        // move past a column edge in the picker.
        .focusable(!pickerOpen)
        .onMoveCommand { direction in handleMove(direction) }
        .onPlayPauseCommand { togglePlay(); bumpOSD() }
        .onTapGesture { togglePlay(); bumpOSD() }
        .onExitCommand {
            if pickerOpen {
                pickerOpen = false
            } else {
                nav.path.removeLast()
            }
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
                    let posSec = Int(duration.components.seconds)
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
                    }
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

    private func handleMove(_ direction: MoveCommandDirection) {
        if pickerOpen { return } // picker handles its own focus internally
        switch direction {
        case .left:
            if #available(tvOS 16.0, *) { proxy.jumpBackward(.seconds(seekStep)) }
            bumpOSD()
        case .right:
            if #available(tvOS 16.0, *) { proxy.jumpForward(.seconds(seekStep)) }
            bumpOSD()
        case .up:
            pickerInitialColumn = .subtitle
            pickerOpen = true
            osdHideTask?.cancel()
        case .down:
            pickerInitialColumn = .audio
            pickerOpen = true
            osdHideTask?.cancel()
        @unknown default:
            break
        }
    }

    private func togglePlay() {
        if session.isPlaying { proxy.pause() } else { proxy.play() }
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

/// Dual-column picker — subtitles left, audio right. Same visual language as
/// HomeView's columns. Up/down wraps within a column; left/right falls through
/// to the focus engine which moves between columns.
private struct PlayerDualPicker: View {
    let subtitleOptions: [PlayerTrackOption]
    let audioOptions: [PlayerTrackOption]
    let currentSubtitleIndex: Int
    let currentAudioIndex: Int
    let initialColumn: PickerColumn
    let onSelectSubtitle: (Int) -> Void
    let onSelectAudio: (Int) -> Void

    @FocusState private var focus: PickerFocus?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            HStack(alignment: .top, spacing: DuplexMetric.columnGap) {
                columnView(
                    title: "Subtitles",
                    options: subtitleOptions,
                    currentIndex: currentSubtitleIndex,
                    column: .subtitle,
                    onSelect: onSelectSubtitle
                )
                columnView(
                    title: "Audio",
                    options: audioOptions,
                    currentIndex: currentAudioIndex,
                    column: .audio,
                    onSelect: onSelectAudio
                )
            }
            .frame(maxWidth: 1080, maxHeight: 640)
            .padding(.horizontal, 40)
        }
        .onAppear {
            focus = makeInitialFocus()
        }
    }

    @ViewBuilder
    private func columnView(
        title: String,
        options: [PlayerTrackOption],
        currentIndex: Int,
        column: PickerColumn,
        onSelect: @escaping (Int) -> Void
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(options) { opt in
                        let focusKey: PickerFocus = column == .subtitle ? .sub(opt.index) : .audio(opt.index)
                        Button {
                            onSelect(opt.index)
                        } label: {
                            PickerRowLabel(
                                option: opt,
                                isCurrent: opt.index == currentIndex
                            )
                        }
                        .buttonStyle(PickerRowButtonStyle())
                        .focused($focus, equals: focusKey)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: 520, maxHeight: 600)
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DuplexMetric.panelRadius)
                .stroke(DuplexColor.border, lineWidth: 1)
        )
        // Group this column for the focus engine so left/right at a column
        // edge moves cleanly to the sibling column instead of jumping to
        // whatever focusable view happens to be nearby outside the picker.
        .focusSection()
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

/// Picker row label — focus styling is applied by `PickerRowButtonStyle`.
private struct PickerRowLabel: View {
    let option: PlayerTrackOption
    let isCurrent: Bool

    var body: some View {
        EntryRowLabel(
            icon: isCurrent ? "✓" : " ",
            title: option.label,
            subtitle: nil,
            meta: nil
        )
    }
}

private struct PickerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleView(configuration: configuration)
    }
    private struct StyleView: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused: Bool
        var body: some View {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isFocused ? DuplexColor.accent : Color.clear)
                    .frame(width: DuplexMetric.selectedBar)
                configuration.label
                    .padding(.vertical, DuplexMetric.rowVPad)
                    .padding(.horizontal, DuplexMetric.rowHPad)
            }
            .background(isFocused ? DuplexColor.accentSoft : Color.clear)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .contentShape(Rectangle())
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

    private var didSeekToResume = false
    private var didApplyDefaults = false
    private var lastHeartbeatTickSecond: Int = -1

    func makeConfiguration(client: DuplexClient, vpath: String) -> VLCVideoPlayer.Configuration {
        var cfg = VLCVideoPlayer.Configuration(url: client.rawURL(path: vpath))
        cfg.autoPlay = true
        return cfg
    }

    func start(client: DuplexClient, vpath: String) async {
        guard case .idle = state else { return }
        state = .loading
        let next: NextResponse? = (try? await client.next(path: vpath)) ?? nil
        state = .playing
        self.nextEntry = next
    }

    func teardown() {
        // Heartbeat already persists; nothing extra to do.
    }

    func handleState(_ state: VLCVideoPlayer.State, info: VLCVideoPlayer.PlaybackInformation, proxy: VLCVideoPlayer.Proxy, vpath: String) {
        ingestTracks(info: info)
        switch state {
        case .opening, .buffering, .esAdded:
            break
        case .playing:
            isPlaying = true
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
        self.positionSeconds = positionSeconds
        self.durationSeconds = totalSeconds
        ingestTracks(info: info)
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
