import AVKit
import SwiftUI
import UIKit

/// SwiftUI wrapper around AVPlayerViewController. The `overlay` closure is
/// installed into `contentOverlayView`, which is the documented place for
/// subtitle overlays / end-of-video cards / etc.
struct AVPlayerViewControllerHost<Overlay: View>: UIViewControllerRepresentable {
    let player: AVPlayer
    @ViewBuilder let overlay: () -> Overlay

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = false
        // Native chrome handles transport controls; we just need an overlay slot.
        let host = UIHostingController(rootView: overlay())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        if let content = vc.contentOverlayView {
            content.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: content.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        context.coordinator.host = host
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        context.coordinator.host?.rootView = overlay()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Overlay>?
    }
}
