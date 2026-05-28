import Foundation

/// Per-directory remembered selection (vpath of containing dir → name of last
/// selected child). Mirrors the `duplex.last:<path>` keys in `web/app.js`.
final class LastSelectionStore: ObservableObject {
    static let shared = LastSelectionStore()

    private let key = "duplex.last"
    private let defaults = UserDefaults.standard
    @Published private(set) var all: [String: String] = [:]

    init() {
        self.all = Self.load(defaults: defaults, key: key)
    }

    private static func load(defaults: UserDefaults, key: String) -> [String: String] {
        guard let data = defaults.data(forKey: key),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return d
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    func get(dir: String) -> String? { all[dir] }

    func set(dir: String, child: String) {
        all[dir] = child
        persist()
    }

    func forgetAll() {
        all.removeAll()
        persist()
    }

    var count: Int { all.count }
}
