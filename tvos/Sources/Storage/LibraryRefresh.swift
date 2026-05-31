import Foundation

/// Tracks explicit "Refresh" actions from Home. The `posterNonce` is appended to
/// poster URLs (`&r=N`) so a refresh changes those URLs, forcing `AsyncImage` to
/// re-load art that may have changed in place (same path, new bytes). It's a
/// freshness nudge, not a cache.
final class LibraryRefresh: ObservableObject {
    static let shared = LibraryRefresh()

    @Published private(set) var posterNonce: Int = 0

    func bump() { posterNonce &+= 1 }
}
