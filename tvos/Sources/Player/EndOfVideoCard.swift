import SwiftUI

struct EndOfVideoCard: View {
    let nextName: String?
    let onContinue: () -> Void
    let onDone: () -> Void

    var body: some View {
        ZStack {
            DuplexColor.bg.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 24) {
                if let nextName {
                    Button(action: onContinue) {
                        HStack(spacing: 14) {
                            Text("▶")
                                .font(.system(size: 30))
                                .foregroundStyle(DuplexColor.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Continue")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(DuplexColor.muted)
                                Text(nextName)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(DuplexColor.fg)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                        .background(DuplexColor.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.card)
                } else {
                    Text("End of video")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(DuplexColor.fg)
                }
                Button("Done", action: onDone)
                    .buttonStyle(.card)
            }
        }
    }
}
