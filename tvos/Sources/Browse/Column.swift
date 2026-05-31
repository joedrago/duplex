import SwiftUI

struct Column<Content: View>: View {
    /// Top-of-content anchor, used to pin the scroll to the very top (showing
    /// the leading padding) when focus enters the first row — `scrollTo` with no
    /// anchor would otherwise land the first row flush against the clip edge,
    /// hiding the padding and clipping the focus-scale above it.
    private static var topAnchorID: String { "duplex.column.top" }

    let title: String
    /// Optional badge shown next to the title (e.g. the current sort mode).
    let badge: String?
    /// When set and non-nil, the column's ScrollView scrolls the minimum needed
    /// to reveal this view's `.id(_:)`-matched row (no-op when already visible).
    let scrollAnchor: AnyHashable?
    /// When true, the next anchor change scrolls fully to the top instead of
    /// doing a minimal reveal — used when focus is in the first row.
    let scrollToTop: Bool
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        badge: String? = nil,
        scrollAnchor: AnyHashable? = nil,
        scrollToTop: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.badge = badge
        self.scrollAnchor = scrollAnchor
        self.scrollToTop = scrollToTop
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .kerning(1.5)
                    .foregroundStyle(DuplexColor.muted)
                if let badge {
                    Text(badge.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .kerning(1.2)
                        .foregroundStyle(DuplexColor.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(DuplexColor.accent.opacity(0.14))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 12)
            Rectangle()
                .fill(DuplexColor.border)
                .frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Leading breathing room, revealed when pinned to top so
                        // the first row's focus-scale isn't clipped.
                        Color.clear.frame(height: 12).id(Self.topAnchorID)
                        content()
                    }
                    .padding(.bottom, 4)
                }
                .onChange(of: scrollAnchor) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        if scrollToTop {
                            // First row: go fully to the top so the leading
                            // padding shows and nothing clips above the poster.
                            proxy.scrollTo(Self.topAnchorID, anchor: .top)
                        } else {
                            // No anchor → minimal reveal; no-op when already
                            // visible (avoids jittery re-centering).
                            proxy.scrollTo(new)
                        }
                    }
                }
            }
        }
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
    }
}

struct EmptyColumn: View {
    let icon: String
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 12) {
            Text(icon).font(.system(size: 64))
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(DuplexColor.fg)
            Text(hint).font(.system(size: 16)).foregroundStyle(DuplexColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 22)
    }
}

struct LoadingColumn: View {
    var body: some View {
        Text("Loading…")
            .font(.system(size: 18))
            .foregroundStyle(DuplexColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

struct ColumnError: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 18))
            .foregroundStyle(DuplexColor.bad)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 40)
            .padding(.horizontal, 22)
    }
}
