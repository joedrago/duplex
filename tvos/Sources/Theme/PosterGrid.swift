import SwiftUI

/// Building blocks for the Posters layout. A `PosterCell` is a 2:3 art box with
/// a small dim caption beneath it; focus styling is driven by an explicit
/// `isFocused` flag because `GridPressCapture` owns the focus engine (same
/// convention as `GridEntryRow`).

enum PosterMetric {
    /// Target on-screen width for a poster in the full-width Browse grid. Sized
    /// to roughly match the Home content columns (3 posters across a ~⅓-screen
    /// column), so posters look consistent between the two screens. The column
    /// count is derived from this regardless of how wide the content area is.
    static let targetWidth: CGFloat = 180
    static let spacing: CGFloat = 24
    static let cornerRadius: CGFloat = 10
    /// 2:3 — height is width × this.
    static let aspect: CGFloat = 1.5

    /// How many columns fit in `width` at roughly `targetWidth` each, clamped to
    /// a sane range so we never get a single giant poster or a wall of tiny ones.
    static func columnCount(forWidth width: CGFloat, min lo: Int = 3, max hi: Int = 10) -> Int {
        guard width > 0 else { return lo }
        let n = Int((width + spacing) / (targetWidth + spacing))
        return Swift.min(hi, Swift.max(lo, n))
    }
}

/// Grid-aware "down" target for a row-major grid of `cols` columns. Returns the
/// key to focus when pressing Down from `cur`, *only* for the case WrapColumns
/// handles poorly: there's no item directly below (we're at the bottom of a
/// short column) but a partial last row exists below us — so we drop to the
/// last item (down-and-to-the-left) instead of wrapping to the top. Returns nil
/// in every other case, leaving WrapColumns' default behavior intact.
func posterGridDownTarget<K: Equatable>(_ keys: [K], from cur: K, cols: Int) -> K? {
    guard cols > 0, let idx = keys.firstIndex(of: cur) else { return nil }
    let count = keys.count
    guard idx + cols >= count else { return nil } // an item is directly below → default
    let curRow = idx / cols
    let lastRow = (count - 1) / cols
    return lastRow > curRow ? keys.last : nil
}

/// Grid-aware "up wrap" target. Wrapping Up from the top row should land in the
/// *last* visual row, but WrapColumns wraps within the focus-column — which for
/// a short column (one with no box in the partial last row) lands a row too
/// high. In that case, return the last item (the bottom-right box, shifted
/// left) instead. Returns nil when the column does reach the last row, leaving
/// WrapColumns' default wrap intact.
func posterGridUpTarget<K: Equatable>(_ keys: [K], from cur: K, cols: Int) -> K? {
    guard cols > 0, let idx = keys.firstIndex(of: cur), idx < cols else { return nil } // top row only
    let count = keys.count
    let lastRow = (count - 1) / cols
    let sameColumnInLastRow = lastRow * cols + (idx % cols)
    return sameColumnInLastRow >= count ? keys.last : nil
}

/// Split `items` into `cols` focus-columns matching a row-major grid layout:
/// item *i* lands in column `i % cols`, preserving row order within each
/// column. Empty trailing columns are dropped. Feeding the result to
/// `WrapColumns` makes its Left/Right + Up/Down behave as 2D grid navigation
/// over the same items a `LazyVGrid(count: cols)` lays out.
func posterStridedColumns<T>(_ items: [T], cols: Int) -> [[T]] {
    guard cols > 0 else { return [items] }
    var out = Array(repeating: [T](), count: cols)
    for (i, item) in items.enumerated() { out[i % cols].append(item) }
    return out.filter { !$0.isEmpty }
}

/// The 2:3 art box alone (no caption). Renders the poster image when a URL is
/// supplied and it loads; otherwise a fallback box (lighter-gray fill, dark
/// border, big glyph). A "wrong"-shaped image is fit on black so it letterboxes
/// rather than stretches or crops — correct 2:3 posters fill the box exactly.
struct PosterArt: View {
    /// Poster image URL, or nil to go straight to the fallback box.
    let url: URL?
    /// Centered glyph for the fallback box (e.g. "🎬" for files, "📁" for dirs).
    let fallbackGlyph: String

    var body: some View {
        ZStack {
            Color.black
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        fallback
                    case .empty:
                        // Still loading — keep the black box; the fallback would
                        // flash for posters that are about to appear.
                        Color.clear
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .aspectRatio(1.0 / PosterMetric.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: PosterMetric.cornerRadius))
    }

    private var fallback: some View {
        ZStack {
            DuplexColor.panel2
            Text(fallbackGlyph)
                .font(.system(size: 64))
                .opacity(0.7)
        }
    }
}

/// A poster cell: the 2:3 art box plus a small caption beneath, with focus
/// styling (accent ring + slight lift) applied to the whole cell.
struct PosterCell: View {
    let url: URL?
    let fallbackGlyph: String
    let title: String
    /// Optional second line under the title (e.g. binge "N remaining" / parent).
    var subtitle: String? = nil
    /// Optional 0...1 progress sliver drawn under the box (Continue Watching).
    var progress: Double? = nil
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            PosterArt(url: url, fallbackGlyph: fallbackGlyph)
                // Progress sliver sits inside the art, inset from the edges so
                // the focus ring (drawn on top, below) never overlaps it.
                .overlay(alignment: .bottom) {
                    progressSliver
                        .padding(.horizontal, 7)
                        .padding(.bottom, 7)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: PosterMetric.cornerRadius)
                        .strokeBorder(isFocused ? DuplexColor.accent : DuplexColor.border,
                                      lineWidth: isFocused ? 4 : 1)
                )
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)

            VStack(spacing: 2) {
                // Lead the caption with the type glyph (📁 / 🎬 / 🍿) so a folder
                // showing its own poster art is still unmistakably a folder.
                Text("\(fallbackGlyph)  \(title)")
                    .font(.system(size: 15, weight: isFocused ? .semibold : .medium))
                    .foregroundStyle(isFocused ? DuplexColor.fg : DuplexColor.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DuplexColor.muted)
                        .lineLimit(1)
                }
            }
            // Reserve room for two title lines (+ optional subtitle) so cells in
            // a row align even when names differ in length.
            .frame(height: subtitle == nil ? 40 : 56, alignment: .top)
            .frame(maxWidth: .infinity)
        }
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .zIndex(isFocused ? 1 : 0)
    }

    @ViewBuilder
    private var progressSliver: some View {
        if let progress, progress > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.6)).frame(height: 5)
                    Capsule()
                        .fill(DuplexColor.accent)
                        .frame(width: max(5, geo.size.width * progress), height: 5)
                }
            }
            .frame(height: 5)
        }
    }
}
