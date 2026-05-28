import SwiftUI

enum DuplexColor {
    static let bg          = Color(hex: 0x07080a)
    static let panel       = Color(hex: 0x0d0f13)
    static let panel2      = Color(hex: 0x14171c)
    static let border      = Color(hex: 0x1a1e25)
    static let fg          = Color(hex: 0xf1f4f8)
    static let muted       = Color(hex: 0x6f7884)
    static let accent      = Color(hex: 0xd4a23a)
    static let accentSoft  = Color(hex: 0xd4a23a).opacity(0.16)
    static let bad         = Color(hex: 0xff6b6b)
    static let good        = Color(hex: 0x5dd28a)
    static let logoDu      = Color(hex: 0x58606e)
    static let logoX       = Color(hex: 0xd4a23a)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >>  8) & 0xff) / 255.0
        let b = Double( hex        & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

enum DuplexMetric {
    static let panelRadius:  CGFloat = 14
    static let rowVPad:      CGFloat = 14
    static let rowHPad:      CGFloat = 22
    static let columnGap:    CGFloat = 24
    static let columnInset:  CGFloat = 28
    static let columnHeader: CGFloat = 18
    static let selectedBar:  CGFloat = 5
}
