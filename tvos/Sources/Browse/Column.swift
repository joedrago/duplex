import SwiftUI

struct Column<Content: View>: View {
    let title: String
    /// Optional badge shown next to the title (e.g. the current sort mode).
    let badge: String?
    /// When set and non-nil, the column's ScrollView scrolls so this view's
    /// `.id(_:)`-matched row is centered. Use this to follow focus changes.
    let scrollAnchor: AnyHashable?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        badge: String? = nil,
        scrollAnchor: AnyHashable? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.badge = badge
        self.scrollAnchor = scrollAnchor
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
                        content()
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: scrollAnchor) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(new, anchor: .center)
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
