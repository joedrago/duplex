import SwiftUI

struct Column<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 18, weight: .semibold))
                .kerning(1.5)
                .foregroundStyle(DuplexColor.muted)
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 12)
            Rectangle()
                .fill(DuplexColor.border)
                .frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    content()
                }
                .padding(.vertical, 4)
            }
        }
        .background(DuplexColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DuplexMetric.panelRadius))
        .focusSection()
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
