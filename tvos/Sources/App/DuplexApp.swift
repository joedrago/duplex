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
}

enum NavDestination: Hashable {
    case browse(path: String)
    case player(vpath: String)
    case settings
    case search

    @ViewBuilder
    func makeView() -> some View {
        switch self {
        case .browse(let path):
            BrowseView(dirPath: path)
        case .player(let vpath):
            // .id(vpath) so that hopping from .player(A) directly to .player(B)
            // (Continue/Done flow) tears down PlayerView A entirely and builds
            // a fresh one for B — otherwise SwiftUI reuses the same view
            // identity, the @StateObject PlayerSession carries over (already
            // .ended), and the underlying VLCMediaPlayer keeps showing A.
            PlayerView(vpath: vpath).id(vpath)
        case .settings:
            SettingsView()
        case .search:
            SearchView()
        }
    }
}
