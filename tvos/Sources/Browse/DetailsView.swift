import SwiftUI

@MainActor
final class DetailsViewModel: ObservableObject {
    enum State {
        case loading
        case loaded(DetailsResponse)
        case failed(String)
    }

    @Published var state: State = .loading
    private let client = DuplexClient()

    func load(vpath: String) async {
        if case .loaded = state { return }
        state = .loading
        do {
            state = .loaded(try await client.details(path: vpath))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// A movie's Details screen. Selecting a title lands here (not straight into
/// playback): poster on the right; title, Letterboxd status, and description
/// down the left; an action menu pinned to the bottom-left.
struct DetailsView: View {
    let vpath: String

    @StateObject private var vm = DetailsViewModel()
    @EnvironmentObject private var nav: NavCoordinator
    @ObservedObject private var resume = ResumeStore.shared
    @ObservedObject private var refresh = LibraryRefresh.shared

    private let client = DuplexClient()

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                LoadingColumn().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let m):
                ColumnError(message: m).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let d):
                content(d)
            }
        }
        .background(DuplexColor.bg.ignoresSafeArea())
        .ignoresSafeArea()
        .navigationBarHidden(true)
        .task { await vm.load(vpath: vpath) }
        .onExitCommand { if !nav.path.isEmpty { nav.path.removeLast() } }
    }

    private func content(_ d: DetailsResponse) -> some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 0) {
                titleBlock(d)
                if let lb = d.letterboxd, !lb.watched.isEmpty || !lb.watchlist.isEmpty {
                    lbLine(lb).padding(.top, 20)
                }
                if let desc = d.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 22))
                        .foregroundStyle(DuplexColor.fg.opacity(0.9))
                        .lineSpacing(6)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.top, 24)
                }
                Spacer(minLength: 28)
                menu(d)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            PosterArt(url: d.poster ? client.posterURL(path: vpath, cacheBust: refresh.posterNonce) : nil,
                      fallbackGlyph: "🎬")
                .frame(width: 380)
                .overlay(
                    RoundedRectangle(cornerRadius: PosterMetric.cornerRadius)
                        .strokeBorder(DuplexColor.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 80)
        .padding(.vertical, 64)
    }

    private func titleBlock(_ d: DetailsResponse) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(d.title)
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(DuplexColor.fg)
                .lineLimit(2)
            if let y = d.year {
                Text(String(y))
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(DuplexColor.muted)
            }
        }
    }

    /// Per-person stars (or "seen") + ❤, plus a dim watchlist entry for anyone
    /// who's only queued the film.
    private func lbLine(_ lb: LbAnnotation) -> some View {
        let seen = Set(lb.watched.map { $0.account })
        return HStack(spacing: 26) {
            ForEach(lb.watched, id: \.account) { w in
                HStack(spacing: 8) {
                    Text(w.account)
                        .font(.system(size: 20))
                        .foregroundStyle(DuplexColor.muted)
                    Text(w.rating.map { DuplexFormat.stars($0) } ?? "seen")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(DuplexColor.accent)
                    if w.liked {
                        Text("❤").font(.system(size: 18))
                    }
                }
            }
            ForEach(lb.watchlist.filter { !seen.contains($0) }, id: \.self) { name in
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 20))
                        .foregroundStyle(DuplexColor.muted)
                    Text("watchlist")
                        .font(.system(size: 18).italic())
                        .foregroundStyle(DuplexColor.muted)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ d: DetailsResponse) -> some View {
        let r = resume.get(vpath)
        let hasResume = (r?.dur ?? 0) > 0 && (r?.pos ?? 0) >= 5 && ((r?.pos ?? 0) <= (r?.dur ?? 0) * 0.95)
        VStack(alignment: .leading, spacing: 14) {
            if hasResume, let r {
                let pct = Int((r.pos / r.dur) * 100)
                DetailsButton(label: "▶  Continue",
                              subtitle: "\(DuplexFormat.time(r.pos)) of \(DuplexFormat.time(r.dur)) · \(pct)%",
                              primary: true) {
                    nav.play(vpath: vpath)
                }
                DetailsButton(label: "↻  Play from Beginning", subtitle: nil, primary: false) {
                    // Player restores from ResumeStore on start; clearing it here
                    // makes it start at 0. New progress is saved as normal.
                    ResumeStore.shared.remove(vpath)
                    nav.play(vpath: vpath)
                }
            } else {
                DetailsButton(label: "▶  Play", subtitle: nil, primary: true) {
                    nav.play(vpath: vpath)
                }
            }
            DetailsButton(label: "←  Back", subtitle: nil, primary: false) {
                if !nav.path.isEmpty { nav.path.removeLast() }
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }
}

/// A focusable action button for the Details menu. Fills gold when focused
/// (primary) or outlines in accent (secondary), matching the app's focus idiom.
private struct DetailsButton: View {
    let label: String
    let subtitle: String?
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 24, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 16, weight: .regular).monospacedDigit())
                        .opacity(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, 22)
        }
        .buttonStyle(DetailsButtonStyle(primary: primary))
    }
}

private struct DetailsButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(primary: primary, configuration: configuration)
    }

    private struct StyleBody: View {
        let primary: Bool
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused: Bool

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isFocused ? DuplexColor.accent : DuplexColor.border,
                                      lineWidth: isFocused ? 3 : 1)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.03 : 1.0))
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }

        private var foreground: Color {
            if primary { return isFocused ? DuplexColor.bg : DuplexColor.fg }
            return DuplexColor.fg
        }

        private var background: Color {
            if primary { return isFocused ? DuplexColor.accent : DuplexColor.accentSoft }
            return isFocused ? DuplexColor.accentSoft : DuplexColor.panel
        }
    }
}
