import SwiftUI

struct BrowseHeader: View {
    let crumbPath: String?      // nil → home (logo only, no crumbs)

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            DuplexLogo(size: 40)
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
