import SwiftUI
import UIKit

/// UIKit bridge that owns Siri Remote focus and forwards arrows / select /
/// play-pause / menu to SwiftUI closures. Used by `WrapColumns` so the grid
/// can implement custom wrap + cross navigation without fighting the focus
/// engine — the engine focuses our transparent view, all directional input
/// arrives here, and the rows are styled manually based on `current == key`.
///
/// Menu handling is selective: if neither `onMenuTap` nor `onMenuHold` is
/// bound, Menu presses are NOT consumed — they flow up the responder chain
/// so SwiftUI's NavigationStack can pop or the system can return to tvOS
/// home. If at least one is bound, we own Menu (and the owner must wire the
/// pop behavior themselves).
struct GridPressCapture: UIViewControllerRepresentable {
    let isActive: Bool
    var onLeft:        () -> Void = {}
    var onRight:       () -> Void = {}
    var onUp:          () -> Void = {}
    var onDown:        () -> Void = {}
    var onSelect:      () -> Void = {}
    var onLongSelect:  () -> Void = {}
    var onPlayPause:   (() -> Void)? = nil
    var onMenuTap:     (() -> Void)? = nil
    var onMenuHold:    (() -> Void)? = nil

    func makeUIViewController(context: Context) -> GridPressCaptureVC {
        let vc = GridPressCaptureVC()
        apply(to: vc)
        return vc
    }

    func updateUIViewController(_ vc: GridPressCaptureVC, context: Context) {
        apply(to: vc)
    }

    private func apply(to vc: GridPressCaptureVC) {
        vc.isActiveForFocus = isActive
        (vc.view as? FocusableTransparentView)?.isFocusEligible = isActive
        vc.onLeft = onLeft
        vc.onRight = onRight
        vc.onUp = onUp
        vc.onDown = onDown
        vc.onSelect = onSelect
        vc.onLongSelect = onLongSelect
        vc.onPlayPause = onPlayPause
        vc.onMenuTap = onMenuTap
        vc.onMenuHold = onMenuHold
        vc.refreshFocus()
    }
}

final class GridPressCaptureVC: UIViewController {
    var isActiveForFocus: Bool = true
    var onLeft:        () -> Void = {}
    var onRight:       () -> Void = {}
    var onUp:          () -> Void = {}
    var onDown:        () -> Void = {}
    var onSelect:      () -> Void = {}
    var onLongSelect:  () -> Void = {}
    var onPlayPause:   (() -> Void)? = nil
    var onMenuTap:     (() -> Void)? = nil
    var onMenuHold:    (() -> Void)? = nil

    private var selectHoldTimer: Timer?
    private var selectHoldFired = false
    private var menuHoldTimer: Timer?
    private var menuHoldFired = false

    private let holdDuration: TimeInterval = 0.55

    override func loadView() {
        let v = FocusableTransparentView()
        v.backgroundColor = .clear
        view = v
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        isActiveForFocus ? [view] : []
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("[Duplex/Grid] viewDidAppear isActive=%d size=%@", isActiveForFocus ? 1 : 0, NSCoder.string(for: view.frame))
        refreshFocus()
    }

    func refreshFocus() {
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private var consumesMenu: Bool { onMenuTap != nil || onMenuHold != nil }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var consumed = false
        for press in presses {
            NSLog("[Duplex/Grid] pressesBegan type=%d active=%d", press.type.rawValue, isActiveForFocus ? 1 : 0)
            switch press.type {
            case .leftArrow, .rightArrow, .upArrow, .downArrow, .playPause:
                consumed = true
            case .select:
                selectHoldFired = false
                selectHoldTimer?.invalidate()
                selectHoldTimer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.selectHoldFired = true
                    self.onLongSelect()
                }
                consumed = true
            case .menu where consumesMenu:
                menuHoldFired = false
                menuHoldTimer?.invalidate()
                if onMenuHold != nil {
                    menuHoldTimer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        self.menuHoldFired = true
                        self.onMenuHold?()
                    }
                }
                consumed = true
            default:
                break
            }
        }
        if !consumed { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var consumed = false
        for press in presses {
            NSLog("[Duplex/Grid] pressesEnded type=%d active=%d", press.type.rawValue, isActiveForFocus ? 1 : 0)
            switch press.type {
            case .leftArrow:  onLeft();  consumed = true
            case .rightArrow: onRight(); consumed = true
            case .upArrow:    onUp();    consumed = true
            case .downArrow:  onDown();  consumed = true
            case .playPause:
                onPlayPause?()
                consumed = true
            case .select:
                selectHoldTimer?.invalidate()
                selectHoldTimer = nil
                if !selectHoldFired { onSelect() }
                selectHoldFired = false
                consumed = true
            case .menu where consumesMenu:
                menuHoldTimer?.invalidate()
                menuHoldTimer = nil
                if !menuHoldFired { onMenuTap?() }
                menuHoldFired = false
                consumed = true
            default:
                break
            }
        }
        if !consumed { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .select:
                selectHoldTimer?.invalidate()
                selectHoldTimer = nil
                selectHoldFired = false
            case .menu where consumesMenu:
                menuHoldTimer?.invalidate()
                menuHoldTimer = nil
                menuHoldFired = false
            default:
                break
            }
        }
        super.pressesCancelled(presses, with: event)
    }
}
