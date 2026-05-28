import SwiftUI

struct BreadcrumbBar: View {
    let path: String
    @EnvironmentObject private var nav: NavCoordinator

    var body: some View {
        let segs = segments(of: path)
        HStack(spacing: 8) {
            crumbButton(label: "duplex", target: "")
            ForEach(Array(segs.enumerated()), id: \.offset) { idx, seg in
                Text("›")
                    .foregroundStyle(DuplexColor.muted)
                let upTo = segs.prefix(idx + 1).joined(separator: "/")
                if idx == segs.count - 1 {
                    Text(seg)
                        .foregroundStyle(DuplexColor.fg)
                        .font(.system(size: 22, weight: .semibold))
                } else {
                    crumbButton(label: seg, target: upTo)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func crumbButton(label: String, target: String) -> some View {
        Button {
            // Navigate to the targeted ancestor by collapsing the stack.
            if target.isEmpty {
                nav.popToRoot()
            } else {
                // Replace the stack with a single browse to the target.
                nav.path = [.browse(path: target)]
            }
        } label: {
            Text(label)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(DuplexColor.accent)
        }
        .buttonStyle(.plain)
    }

    private func segments(of vpath: String) -> [String] {
        vpath.split(separator: "/").map(String.init)
    }
}
