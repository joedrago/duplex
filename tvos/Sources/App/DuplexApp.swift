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
    }
}

@MainActor
final class NavCoordinator: ObservableObject {
    @Published var path: [NavDestination] = []

    func push(_ dest: NavDestination) { path.append(dest) }
    func popToRoot() { path.removeAll() }

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
