import SwiftUI

struct ContinueRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let progress: Double      // 0...1
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        // Two sibling buttons in an HStack so the tvOS focus engine sees them
        // as independently focusable. Nesting Buttons traps focus on the outer.
        HStack(spacing: 0) {
            Button(action: onSelect) {
                ContinueRowMainLabel(icon: icon, title: title, subtitle: subtitle, progress: progress)
            }
            .buttonStyle(EntryRowButtonStyle())

            Button(action: onRemove) {
                Text("✕")
            }
            .buttonStyle(RemoveButtonStyle())
            .accessibilityLabel("Forget \(title)")
        }
    }
}

private struct ContinueRowMainLabel: View {
    let icon: String
    let title: String
    let subtitle: String?
    let progress: Double

    var body: some View {
        VStack(spacing: 6) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleView(configuration: configuration)
    }

    private struct StyleView: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused: Bool

        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(isFocused ? DuplexColor.bad : DuplexColor.muted)
                .frame(width: 72, height: 72)
                .background(isFocused ? DuplexColor.bad.opacity(0.18) : Color.clear)
                .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isFocused)
                .contentShape(Rectangle())
        }
    }
}
