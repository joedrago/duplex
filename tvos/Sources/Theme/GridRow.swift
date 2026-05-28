import SwiftUI

/// Non-Button row variants for use inside `WrapColumns`. Focus styling is
/// driven by an explicit `isFocused: Bool` instead of `@Environment(\.isFocused)`
/// because the focus engine is taken over by the grid's press-capture host.

struct GridEntryRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let meta: String?
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isFocused ? DuplexColor.accent : Color.clear)
                .frame(width: DuplexMetric.selectedBar)
            EntryRowLabel(icon: icon, title: title, subtitle: subtitle, meta: meta)
                .padding(.vertical, DuplexMetric.rowVPad)
                .padding(.horizontal, DuplexMetric.rowHPad)
        }
        .background(isFocused ? DuplexColor.accentSoft : Color.clear)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .contentShape(Rectangle())
    }
}

struct GridContinueRow: View {
    let title: String
    let subtitle: String?
    let progress: Double
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isFocused ? DuplexColor.accent : Color.clear)
                .frame(width: DuplexMetric.selectedBar)
            VStack(spacing: 6) {
                HStack(alignment: .center, spacing: 14) {
                    Text("🎬")
                        .font(.system(size: 26))
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle.uppercased())
                                .font(.system(size: 14, weight: .semibold))
                                .kerning(0.6)
                                .foregroundStyle(DuplexColor.muted)
                                .lineLimit(1)
                        }
                        Text(title)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(DuplexColor.fg)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if isFocused {
                        Text("Hold ✓ to forget")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DuplexColor.muted)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(DuplexColor.border).frame(height: 3)
                        Rectangle()
                            .fill(DuplexColor.accent)
                            .frame(width: max(0, geo.size.width * progress), height: 3)
                    }
                }
                .frame(height: 3)
            }
            .padding(.vertical, DuplexMetric.rowVPad)
            .padding(.horizontal, DuplexMetric.rowHPad)
        }
        .background(isFocused ? DuplexColor.accentSoft : Color.clear)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .contentShape(Rectangle())
    }
}
