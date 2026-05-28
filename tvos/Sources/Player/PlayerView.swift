import AVKit
import SwiftUI

/// Phase 1 player. For non-MKV containers, hands `/api/raw` straight to AVPlayer
/// and lets AVPlayerViewController provide all of the chrome. MKV gets a
/// "not yet supported" card until Phase 2 lands.
struct PlayerView: View {
    let vpath: String

    @StateObject private var loader = PlayerLoader()
    @EnvironmentObject private var nav: NavCoordinator

    var body: some View {
        ZStack {
            DuplexColor.bg.ignoresSafeArea()
            switch loader.state {
            case .idle, .loading:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(DuplexColor.accent)
            case .unsupportedContainer(let reason):
                PlayerErrorCard(
                    icon: "🧩",
                    title: "Not yet supported",
                    detail: reason
                )
            case .failed(let msg):
                PlayerErrorCard(
                    icon: "⚠️",
                    title: "Couldn't play this file",
                    detail: msg
                )
            case .ready(let manifest, let coordinator):
                playerSurface(manifest: manifest, coordinator: coordinator)
            }
        }
        .task { await loader.load(vpath: vpath) }
        .onDisappear { loader.teardown() }
        .navigationBarHidden(true)
    }

    @ViewBuilder
    private func playerSurface(manifest: Manifest, coordinator: PlayerCoordinator) -> some View {
        AVPlayerViewControllerHost(player: coordinator.player) {
            PlayerOverlay(coordinator: coordinator, manifest: manifest, vpath: vpath)
        }
        .ignoresSafeArea()
    }
}

private struct PlayerOverlay: View {
    @ObservedObject var coordinator: PlayerCoordinator
    let manifest: Manifest
    let vpath: String

    @State private var nextEntry: NextResponse?
    @State private var nextLoaded = false
    @State private var dismissEndCard = false

    @EnvironmentObject private var nav: NavCoordinator

    var body: some View {
        ZStack {
            SubtitleOverlay(coordinator: coordinator, manifest: manifest)
            if coordinator.didEnd && !dismissEndCard {
                EndOfVideoCard(
                    nextName: nextEntry?.name,
                    onContinue: {
                        if let next = nextEntry {
                            nav.path.removeLast()
                            nav.push(.player(vpath: next.vpath))
                        }
                    },
                    onDone: {
                        dismissEndCard = true
                        nav.path.removeLast()
                    }
                )
            }
        }
        .task(id: coordinator.didEnd) {
            guard coordinator.didEnd, !nextLoaded else { return }
            nextLoaded = true
            nextEntry = try? await DuplexClient().next(path: vpath)
        }
    }
}

@MainActor
final class PlayerLoader: ObservableObject {
    enum State {
        case idle
        case loading
        case unsupportedContainer(String)
        case ready(Manifest, PlayerCoordinator)
        case failed(String)
    }

    @Published var state: State = .idle
    private let client = DuplexClient()

    func load(vpath: String) async {
        guard case .idle = state else { return }
        state = .loading

        // Cheap pre-check on extension — saves a round trip for the common case.
        let ext = (vpath as NSString).pathExtension.lowercased()
        if ext == "mkv" || ext == "mka" || ext == "webm" {
            state = .unsupportedContainer(
                "MKV / WebM playback isn't wired up yet on tvOS. The web client demuxes these in the browser via Mediabunny; the native client will gain an FFmpeg remuxer in Phase 2."
            )
            return
        }

        do {
            let manifest = try await client.manifest(path: vpath)
            // Server reports container; double-check in case extension lied.
            if manifest.container.contains("matroska") || manifest.container.contains("webm") {
                state = .unsupportedContainer("Matroska container (\(manifest.container)) — Phase 2 work.")
                return
            }
            let coord = PlayerCoordinator(url: client.rawURL(path: vpath), vpath: vpath)
            state = .ready(manifest, coord)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func teardown() {
        if case .ready(_, let coord) = state {
            coord.teardown()
        }
    }
}
