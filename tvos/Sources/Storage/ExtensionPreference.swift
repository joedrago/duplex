import Foundation

/// Whether file extensions are shown in the UI. Hidden by default —
/// "direct_sidecar.mp4" displays as "direct_sidecar". A Settings toggle flips it.
///
/// Views that render file names observe this (`@ObservedObject`) so they
/// re-render when the toggle changes; the actual stripping lives in
/// `DuplexFormat.displayFileName`.
final class ExtensionPreference: ObservableObject {
    static let shared = ExtensionPreference()
    private let key = "duplex.showExtensions"
    private let defaults = UserDefaults.standard

    @Published var showExtensions: Bool {
        didSet { defaults.set(showExtensions, forKey: key) }
    }

    init() {
        // Absent key → false → hidden, which is the desired default.
        self.showExtensions = defaults.bool(forKey: key)
    }

    func toggle() { showExtensions.toggle() }
}
