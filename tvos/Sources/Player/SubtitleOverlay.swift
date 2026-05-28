import SwiftUI

/// Rendered on top of AVPlayerViewController's content via the overlay slot.
/// Phase 1 supports sidecar VTT/SRT/ASS-as-text/SubViewer; embedded subtitle
/// tracks come in Phase 3.
struct SubtitleOverlay: View {
    @ObservedObject var coordinator: PlayerCoordinator
    let manifest: Manifest

    @State private var cues: [SubtitleCue] = []
    @State private var activeSidecar: SidecarEntry?
    @State private var pickerVisible: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let cue = SubtitleParser.activeCue(in: cues, at: coordinator.currentTime) {
                SubtitleText(text: cue.text)
                    .padding(.bottom, 80)
                    .transition(.opacity)
            }
        }
        .task(id: manifest.path) {
            // Auto-pick: first English sidecar if any; else the first.
            if let pick = preferredSidecar(in: manifest.sidecars) {
                await load(sidecar: pick)
            }
        }
    }

    private func preferredSidecar(in list: [SidecarEntry]) -> SidecarEntry? {
        if let en = list.first(where: { ($0.language ?? "").lowercased().hasPrefix("en") }) {
            return en
        }
        return list.first
    }

    private func load(sidecar: SidecarEntry) async {
        let url = DuplexClient().baseURL.appendingPathComponent(
            sidecar.url.hasPrefix("/") ? String(sidecar.url.dropFirst()) : sidecar.url
        )
        // sidecar.url already includes the query string ("/api/sidecar?path=…&index=…"),
        // appendingPathComponent doesn't handle queries — build it correctly.
        guard let fullURL = URL(string: sidecar.url, relativeTo: DuplexClient().baseURL) else {
            _ = url
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: fullURL)
            let text = String(data: data, encoding: .utf8) ?? ""
            let parsed = SubtitleParser.parse(text)
            await MainActor.run {
                self.activeSidecar = sidecar
                self.cues = parsed
            }
        } catch {
            // Surfacing parse failures isn't a Phase 1 goal — silent fall-through.
        }
    }
}

private struct SubtitleText: View {
    let text: String

    var body: some View {
        Text(text)
            .multilineTextAlignment(.center)
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.85), radius: 4, x: 0, y: 2)
            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
            .padding(.horizontal, 60)
    }
}
