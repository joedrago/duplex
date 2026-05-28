import SwiftUI

/// Pure display — non-interactive. Navigation up the path is done with Menu
/// on the remote (NavigationStack pop). Making crumbs focusable would steal
/// arrow keys away from the column grid below.
struct BreadcrumbBar: View {
    let path: String

    var body: some View {
        let segs = segments(of: path)
        HStack(spacing: 8) {
            Text("duplex")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(DuplexColor.muted)
            ForEach(Array(segs.enumerated()), id: \.offset) { idx, seg in
                Text("›")
                    .foregroundStyle(DuplexColor.muted)
                let isLast = idx == segs.count - 1
                Text(seg)
                    .font(.system(size: 22, weight: isLast ? .semibold : .medium))
                    .foregroundStyle(isLast ? DuplexColor.fg : DuplexColor.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func segments(of vpath: String) -> [String] {
        vpath.split(separator: "/").map(String.init)
    }
}
