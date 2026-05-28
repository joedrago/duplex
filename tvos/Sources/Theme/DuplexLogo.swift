import SwiftUI

struct DuplexLogo: View {
    var size: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            Text("du").foregroundStyle(DuplexColor.logoDu)
            Text("ple").foregroundStyle(DuplexColor.fg)
            Text("x").foregroundStyle(DuplexColor.logoX)
        }
        .font(.system(size: size, weight: .heavy, design: .default))
        .kerning(-0.5)
    }
}
