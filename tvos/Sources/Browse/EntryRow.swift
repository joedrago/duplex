import SwiftUI

struct EntryRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let meta: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EntryRowLabel(icon: icon, title: title, subtitle: subtitle, meta: meta)
        }
        .buttonStyle(EntryRowButtonStyle())
    }
}

struct EntryRowLabel: View {
    let icon: String
    let title: String
    let subtitle: String?
    let meta: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(icon)
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
            if let meta, !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 16, weight: .regular).monospacedDigit())
                    .foregroundStyle(DuplexColor.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EntryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleView(configuration: configuration)
    }

    private struct StyleView: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused: Bool

        var body: some View {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isFocused ? DuplexColor.accent : Color.clear)
                    .frame(width: DuplexMetric.selectedBar)
                configuration.label
                    .padding(.vertical, DuplexMetric.rowVPad)
                    .padding(.horizontal, DuplexMetric.rowHPad)
            }
            .background(isFocused ? DuplexColor.accentSoft : Color.clear)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .contentShape(Rectangle())
        }
    }
}
