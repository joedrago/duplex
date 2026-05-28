import SwiftUI
import UIKit

/// UIKit bridge that captures press-began / press-ended for the Siri Remote.
/// SwiftUI's `.onMoveCommand` is one-shot — it can't tell you when a button is
/// released, which is exactly what we need for hold-to-scrub.
///
/// The wrapped view is transparent and fills its container. Make it focusable
/// only when no other overlay (e.g. the audio/subtitle picker) wants focus.
struct PlayerRemoteInput: UIViewControllerRepresentable {
    let isActive: Bool
    var onLeftBegan: () -> Void = {}
    var onLeftEnded: () -> Void = {}
    var onRightBegan: () -> Void = {}
    var onRightEnded: () -> Void = {}
    var onUpTap: () -> Void = {}
    var onDownTap: () -> Void = {}
    var onSelectTap: () -> Void = {}
    var onPlayPauseTap: () -> Void = {}
    var onMenuTap: () -> Void = {}

    func makeUIViewController(context: Context) -> RemotePressCaptureVC {
        let vc = RemotePressCaptureVC()
        update(vc)
        return vc
    }

    func updateUIViewController(_ vc: RemotePressCaptureVC, context: Context) {
        update(vc)
    }

    private func update(_ vc: RemotePressCaptureVC) {
        vc.isActiveForFocus = isActive
        (vc.view as? FocusableTransparentView)?.isFocusEligible = isActive
        vc.onLeftBegan = onLeftBegan
        vc.onLeftEnded = onLeftEnded
        vc.onRightBegan = onRightBegan
        vc.onRightEnded = onRightEnded
        vc.onUpTap = onUpTap
        vc.onDownTap = onDownTap
        vc.onSelectTap = onSelectTap
        vc.onPlayPauseTap = onPlayPauseTap
        vc.onMenuTap = onMenuTap
        vc.refreshFocus()
    }
}

final class RemotePressCaptureVC: UIViewController {
    var isActiveForFocus: Bool = true
    var onLeftBegan: () -> Void = {}
    var onLeftEnded: () -> Void = {}
    var onRightBegan: () -> Void = {}
    var onRightEnded: () -> Void = {}
    var onUpTap: () -> Void = {}
    var onDownTap: () -> Void = {}
    var onSelectTap: () -> Void = {}
    var onPlayPauseTap: () -> Void = {}
    var onMenuTap: () -> Void = {}

    override func loadView() {
        let v = FocusableTransparentView()
        v.backgroundColor = .clear
        view = v
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { isActiveForFocus ? [view] : [] }

    func refreshFocus() {
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:  onLeftBegan();  handled = true
            case .rightArrow: onRightBegan(); handled = true
            case .upArrow, .downArrow, .select, .playPause, .menu:
                // wait for pressesEnded to count as a "tap" — avoids double-fire
                handled = true
            default:
                break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:  onLeftEnded();   handled = true
            case .rightArrow: onRightEnded();  handled = true
            case .upArrow:    onUpTap();       handled = true
            case .downArrow:  onDownTap();     handled = true
            case .select:     onSelectTap();   handled = true
            case .playPause:  onPlayPauseTap(); handled = true
            case .menu:       onMenuTap();     handled = true
            default:
                break
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Treat cancelled presses as ended so we never strand a "still holding"
        // state if the remote drops the release event.
        for press in presses {
            switch press.type {
            case .leftArrow:  onLeftEnded()
            case .rightArrow: onRightEnded()
            default: break
            }
        }
        super.pressesCancelled(presses, with: event)
    }
}

/// A UIView that reports itself as focusable so the system delivers presses to
/// the hosting view controller's `pressesBegan` overrides. Toggled via
/// `isFocusEligible` so the picker overlay can take focus exclusively.
final class FocusableTransparentView: UIView {
    var isFocusEligible: Bool = true
    override var canBecomeFocused: Bool { isFocusEligible }
}
