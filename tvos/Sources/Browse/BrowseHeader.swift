import SwiftUI

struct BrowseHeader: View {
    let crumbPath: String?      // nil → home (logo only, no crumbs)

    @ObservedObject private var houseParty = HousePartyStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            DuplexLogo(size: 40)
            if houseParty.joined {
                HousePartyBadge()
            }
            if let crumbPath, !crumbPath.isEmpty {
                BreadcrumbBar(path: crumbPath)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }
}

/// Cute pill shown next to the logo while in House Party mode, so it's always
/// obvious you're mirroring the room.
struct HousePartyBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("🎉")
            Text("House Party")
                .font(.system(size: 18, weight: .heavy))
                .kerning(0.3)
        }
        .foregroundStyle(DuplexColor.bg)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(DuplexColor.accent)
        )
    }
}
