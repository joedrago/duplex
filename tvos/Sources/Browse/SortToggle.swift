import SwiftUI

struct SortToggle: View {
    @ObservedObject var pref: SortPreference

    var body: some View {
        HStack(spacing: 0) {
            pill("Name", active: pref.mode == .name) { pref.mode = .name }
            pill("Recent", active: pref.mode == .recent) { pref.mode = .recent }
        }
        .background(DuplexColor.panel2)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DuplexColor.border, lineWidth: 1))
    }

    private func pill(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(active ? DuplexColor.bg : DuplexColor.fg)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(active ? DuplexColor.accent : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
