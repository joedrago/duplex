import SwiftUI

struct BrowseHeader: View {
    let crumbPath: String?      // nil → home (no crumbs, logo only)
    let showSort: Bool
    @ObservedObject var sort: SortPreference
    @EnvironmentObject private var nav: NavCoordinator

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Button { nav.popToRoot() } label: {
                DuplexLogo(size: 40)
            }
            .buttonStyle(.plain)

            if let crumbPath, !crumbPath.isEmpty {
                BreadcrumbBar(path: crumbPath)
            } else {
                Spacer(minLength: 0)
            }

            if showSort {
                SortToggle(pref: sort)
            }

            Button { nav.push(.settings) } label: {
                Text("⚙")
                    .font(.system(size: 30))
                    .foregroundStyle(DuplexColor.fg)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }
}
