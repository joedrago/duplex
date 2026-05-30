import SwiftUI

@main
struct DuplexApp: App {
    init() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        NSLog("[Duplex] launched v%@ build %@  server=%@", v, b, AppConfig.serverURL.absoluteString)
        let home = NSHomeDirectory()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "?"
        let resumeBytes = UserDefaults.standard.data(forKey: "duplex.resume")?.count ?? 0
        let resumeCount = ResumeStore.shared.allRaw.count
        NSLog("[Duplex/Container] home=%@ docs=%@ resumeBytes=%d resumeCount=%d", home, docs, resumeBytes, resumeCount)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var nav = NavCoordinator()

    var body: some View {
        NavigationStack(path: $nav.path) {
            HomeView()
                .environmentObject(nav)
                .navigationDestination(for: NavDestination.self) { dest in
                    dest.makeView()
                        .environmentObject(nav)
                }
        }
        .preferredColorScheme(.dark)
        .background(DuplexColor.bg.ignoresSafeArea())
        .onAppear {
            // Give the House Party store a handle to navigation so it can mirror
            // the party (start/stop the shared video). Set once.
            HousePartyStore.shared.nav = nav
        }
    }
}

@MainActor
final class NavCoordinator: ObservableObject {
    @Published var path: [NavDestination] = []

    func push(_ dest: NavDestination) { path.append(dest) }
    func popToRoot() { path.removeAll() }

    /// The vpath of the player at the top of the stack, if we're currently in a
    /// player. Used by `HousePartyStore` to decide whether the party's video is
    /// already the one we're playing.
    var currentPlayerVpath: String? {
        if case .player(let vpath, _) = path.last { return vpath }
        return nil
    }

    /// Start (or swap to) a video because the House Party told us to mirror it.
    /// Bypasses the binge-chooser interception in `play(_:)` — mirroring is never
    /// a binge play — and swaps the top atomically when we're already in a
    /// different player (the same race-free trick `PlayerView.playNext` uses).
    func playFromHouseParty(vpath: String) {
        if !path.isEmpty, case .player = path[path.count - 1] {
            path[path.count - 1] = .player(vpath: vpath, bingeId: nil)
        } else {
            push(.player(vpath: vpath, bingeId: nil))
        }
    }

    /// Single choke point for starting playback of a video.
    ///
    /// - When `bingeId` is set the play is already bound to a binge: go
    ///   straight to the player, no interception.
    /// - Otherwise (library, Continue Watching, recent, search) check whether
    ///   this vpath is the next-up video of any binge. If so, route through the
    ///   chooser so the user can attach this playback to a binge; if not, play
    ///   it plainly.
    func play(vpath: String, bingeId: String? = nil) {
        if bingeId != nil {
            push(.player(vpath: vpath, bingeId: bingeId))
            return
        }
        if BingeStore.shared.bingesWithFront(vpath).isEmpty {
            push(.player(vpath: vpath, bingeId: nil))
        } else {
            push(.bingeChooser(vpath: vpath))
        }
    }

    /// Resolve the chooser by swapping it off the stack for the player, so
    /// backing out of playback returns to the screen the user started from
    /// (not the chooser). `bingeId == nil` means "play unattached".
    func resolveChooser(vpath: String, bingeId: String?) {
        guard !path.isEmpty, case .bingeChooser = path[path.count - 1] else {
            push(.player(vpath: vpath, bingeId: bingeId))
            return
        }
        path[path.count - 1] = .player(vpath: vpath, bingeId: bingeId)
    }
}

enum NavDestination: Hashable {
    case browse(path: String)
    case player(vpath: String, bingeId: String?)
    case bingeChooser(vpath: String)
    case settings
    case search

    @ViewBuilder
    func makeView() -> some View {
        switch self {
        case .browse(let path):
            BrowseView(dirPath: path)
        case .player(let vpath, let bingeId):
            // .id(vpath) so that hopping from .player(A) directly to .player(B)
            // (Continue/Done flow) tears down PlayerView A entirely and builds
            // a fresh one for B — otherwise SwiftUI reuses the same view
            // identity, the @StateObject PlayerSession carries over (already
            // .ended), and the underlying VLCMediaPlayer keeps showing A.
            PlayerView(vpath: vpath, bingeId: bingeId).id(vpath)
        case .bingeChooser(let vpath):
            BingeChooserView(vpath: vpath)
        case .settings:
            SettingsView()
        case .search:
            SearchView()
        }
    }
}
