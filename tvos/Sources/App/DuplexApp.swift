import SwiftUI

@main
struct DuplexApp: App {
    init() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        NSLog("[Duplex] launched v%@ build %@  server=%@", v, b, AppConfig.serverURL.absoluteString)
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

    @ViewBuilder
    func makeView() -> some View {
        switch self {
        case .browse(let path):
            BrowseView(dirPath: path)
        case .player(let vpath):
            PlayerView(vpath: vpath)
        case .settings:
            SettingsView()
        }
    }
}
