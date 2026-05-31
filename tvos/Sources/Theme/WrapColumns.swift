import SwiftUI

/// Direction passed to `WrapColumns.crossNavigate`. Top-level rather than
/// nested inside the generic struct so callers can write the closure type
/// without binding to a specific `WrapColumns` specialization. Includes the
/// vertical directions so callers can override up/down too (e.g. grid layouts
/// that want to drop diagonally into a partial last row instead of wrapping).
enum WrapColumnsCrossDirection { case left, right, up, down }

/// Reusable multi-column focus grid for tvOS.
///
/// - Up / Down wrap inside a column (top → bottom, bottom → top) on a tap.
///   When the arrow is held long enough to trigger auto-repeat scrolling,
///   movement clamps at the ends instead of wrapping.
/// - Left / Right move to the same row index in the sibling column (clamped
///   to the peer's last row if shorter). When the same-row default makes no
///   semantic sense (e.g. crossing between a name list and an alphabet rail),
///   the caller can override with `crossNavigate`.
/// - Select fires `onActivate(currentKey)`.
/// - Hold-Select (~0.55s) fires `onLongSelect(currentKey)` if bound.
/// - Play/Pause / Menu-tap / Menu-hold fire their respective optional
///   callbacks. Menu is only consumed if at least one Menu callback is set.
///
/// The grid takes full ownership of arrow input via a UIKit press-capture
/// host while `isActive` is true. Surrounding focusable views are unreachable
/// during that time, which is intentional — wrap behavior would otherwise be
/// hijacked by header buttons. Set `isActive` to false to hand focus back to
/// the SwiftUI engine (e.g. when an overlay opens above this grid).
///
/// The caller is responsible for the visual layout. `WrapColumns` only
/// describes the focus topology (`columns: [[Key]]`) and supplies a binding
/// to the current focused key. Use that binding to drive your row styling
/// and to scroll the active column to the focused row.
struct WrapColumns<Key: Hashable, Content: View>: View {
    let columns: [[Key]]
    @Binding var current: Key?
    var isActive: Bool = true
    var onActivate:    (Key) -> Void
    var onLongSelect:  ((Key) -> Void)? = nil
    var onPlayPause:   (() -> Void)? = nil
    var onMenuTap:     (() -> Void)? = nil
    var onMenuHold:    (() -> Void)? = nil

    /// Caller-supplied override for left/right cross-column navigation. Invoked
    /// with the currently focused key and the direction the user pressed. Return
    /// the key to focus on the peer column, or nil to fall back to the default
    /// same-row mapping. The returned key must exist in `columns`, else the
    /// default mapping is used.
    var crossNavigate: ((Key, WrapColumnsCrossDirection) -> Key?)? = nil

    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                GridPressCapture(
                    isActive: isActive,
                    onLeft:       { move(.left) },
                    onRight:      { move(.right) },
                    onUp:         { isAutoRepeat in move(.up, wrap: !isAutoRepeat) },
                    onDown:       { isAutoRepeat in move(.down, wrap: !isAutoRepeat) },
                    onSelect:     { if let k = current { onActivate(k) } },
                    onLongSelect: { if let k = current, let cb = onLongSelect { cb(k) } },
                    onPlayPause:  onPlayPause,
                    onMenuTap:    onMenuTap,
                    onMenuHold:   onMenuHold
                )
            )
            .onAppear { ensureValidFocus() }
            .onChange(of: columns) { _, _ in ensureValidFocus() }
    }

    private enum Dir {
        case up, down, left, right

        var crossDir: WrapColumnsCrossDirection {
            switch self {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            }
        }
    }

    private func ensureValidFocus() {
        if let cur = current, columns.contains(where: { $0.contains(cur) }) { return }
        current = columns.first(where: { !$0.isEmpty })?.first
    }

    private func move(_ dir: Dir, wrap: Bool = true) {
        guard !columns.isEmpty else { return }
        guard let cur = current,
              let colIdx = columns.firstIndex(where: { $0.contains(cur) }),
              let rowIdx = columns[colIdx].firstIndex(of: cur) else {
            ensureValidFocus()
            return
        }
        let col = columns[colIdx]
        // The caller gets first say. For up/down this lets a grid layout drop
        // diagonally into a partial last row; for left/right it remaps
        // cross-column jumps (e.g. list ↔ alphabet rail). Only on a tap
        // (wrap == true) — during auto-repeat scrolling we keep the
        // clamp-at-ends behavior. (Left/right are always taps.)
        if wrap, let o = crossOverride(from: cur, dir.crossDir) {
            current = o
            return
        }
        switch dir {
        case .up:
            if rowIdx == 0 {
                current = wrap ? col.last : cur
            } else {
                current = col[rowIdx - 1]
            }
        case .down:
            if rowIdx == col.count - 1 {
                current = wrap ? col.first : cur
            } else {
                current = col[rowIdx + 1]
            }
        case .left:
            current = peerKey(rowIdx: rowIdx, col: colIdx - 1) ?? cur
        case .right:
            current = peerKey(rowIdx: rowIdx, col: colIdx + 1) ?? cur
        }
    }

    private func crossOverride(from cur: Key, _ dir: WrapColumnsCrossDirection) -> Key? {
        guard let candidate = crossNavigate?(cur, dir),
              columns.contains(where: { $0.contains(candidate) }) else { return nil }
        return candidate
    }

    private func peerKey(rowIdx: Int, col idx: Int) -> Key? {
        guard idx >= 0 && idx < columns.count else { return nil }
        let peer = columns[idx]
        guard !peer.isEmpty else { return nil }
        return peer[min(rowIdx, peer.count - 1)]
    }
}
