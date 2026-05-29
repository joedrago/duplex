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
    var onUp:          (_ isAutoRepeat: Bool) -> Void = { _ in }
    var onDown:        (_ isAutoRepeat: Bool) -> Void = { _ in }
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
        let activeChanged = vc.isActiveForFocus != isActive
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
        if activeChanged {
            // isActive flips when an overlay (e.g. a binge confirm alert) presents
            // or dismisses. Calling updateFocusIfNeeded() synchronously here — from
            // inside SwiftUI's update pass — triggers an AttributeGraph cycle that
            // can wedge the focus engine and leave a screen blank. Defer it.
            DispatchQueue.main.async { [weak vc] in vc?.refreshFocus() }
        } else {
            vc.refreshFocus()
        }
    }
}

final class GridPressCaptureVC: UIViewController {
    var isActiveForFocus: Bool = true
    var onLeft:        () -> Void = {}
    var onRight:       () -> Void = {}
    var onUp:          (_ isAutoRepeat: Bool) -> Void = { _ in }
    var onDown:        (_ isAutoRepeat: Bool) -> Void = { _ in }
    var onSelect:      () -> Void = {}
    var onLongSelect:  () -> Void = {}
    var onPlayPause:   (() -> Void)? = nil
    var onMenuTap:     (() -> Void)? = nil
    var onMenuHold:    (() -> Void)? = nil

    private var selectHoldTimer: Timer?
    private var selectHoldFired = false
    private var menuHoldTimer: Timer?
    private var menuHoldFired = false

    /// Hold-to-scroll: when the user holds the up or down arrow on a list,
    /// keep firing `onUp` / `onDown` at an accelerating rate. Mirrors the
    /// player's scrub pattern so the interaction model feels consistent.
    private enum HoldDir { case up, down }
    private var holdDir: HoldDir?
    private var holdStartedAt: Date?
    private var holdTimer: Timer?

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
            case .upArrow:
                startHold(.up)
                consumed = true
            case .downArrow:
                startHold(.down)
                consumed = true
            case .leftArrow, .rightArrow, .playPause:
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
            case .upArrow:    endHold(); consumed = true
            case .downArrow:  endHold(); consumed = true
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
            case .upArrow, .downArrow:
                endHold()
            default:
                break
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - hold-to-scroll

    private func startHold(_ dir: HoldDir) {
        endHold()
        holdDir = dir
        holdStartedAt = Date()
        // Immediate single-step so a quick tap moves exactly one row.
        fireHoldStep(dir, count: 1, isAutoRepeat: false)
        // Tick frequently; the first ~0.4s of ticks deliberately produce zero
        // steps so a hold under that threshold still feels like a single tap.
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.holdTick() }
        }
    }

    private func endHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdDir = nil
        holdStartedAt = nil
    }

    private func holdTick() {
        guard let dir = holdDir, let started = holdStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        let stepsThisTick = holdStepsForElapsed(elapsed)
        if stepsThisTick > 0 {
            fireHoldStep(dir, count: stepsThisTick, isAutoRepeat: true)
        }
    }

    /// Per-tick step count while the arrow is held. Curve mirrors the player's
    /// scrub-acceleration shape: nothing for the first ~0.4s (so tap stays a
    /// tap), then steadily faster the longer the press is held.
    ///
    ///   <0.4s : 0 steps/tick (single-tap range)
    ///   <1.0s : 1 step/tick  (~10 rows/sec)
    ///   <2.5s : 2 steps/tick (~20 rows/sec)
    ///   <5.0s : 4 steps/tick (~40 rows/sec)
    ///   ≥5.0s : 8 steps/tick (~80 rows/sec)
    private func holdStepsForElapsed(_ elapsed: TimeInterval) -> Int {
        switch elapsed {
        case ..<0.4: return 0
        case ..<1.0: return 1
        case ..<2.5: return 2
        case ..<5.0: return 4
        default:     return 8
        }
    }

    private func fireHoldStep(_ dir: HoldDir, count: Int, isAutoRepeat: Bool) {
        for _ in 0..<count {
            switch dir {
            case .up:   onUp(isAutoRepeat)
            case .down: onDown(isAutoRepeat)
            }
        }
    }
}
