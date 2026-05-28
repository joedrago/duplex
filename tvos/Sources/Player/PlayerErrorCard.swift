import SwiftUI

struct PlayerErrorCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 18) {
            Text(icon).font(.system(size: 80))
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(DuplexColor.fg)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 22))
                .foregroundStyle(DuplexColor.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DuplexColor.bg.ignoresSafeArea())
    }
}
