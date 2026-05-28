import Foundation

struct ResumeEntry: Codable, Hashable {
    var pos: Double
    var dur: Double
    var at: Double   // unix seconds
}

/// UserDefaults-backed map of vpath → ResumeEntry. Mirrors `duplex.resume`
/// localStorage usage in `web/app.js`.
///
/// On read, entries with `pos < 5s` or `pos > 0.95 * dur` are pruned — matches
/// the web heuristic that we don't bother resuming "barely started" or
/// "essentially finished" videos.
final class ResumeStore: ObservableObject {
    static let shared = ResumeStore()

    private let key = "duplex.resume"
    private let defaults = UserDefaults.standard
    @Published private(set) var allRaw: [String: ResumeEntry] = [:]

    init() {
        self.allRaw = Self.load(defaults: defaults, key: key)
    }

    private static func load(defaults: UserDefaults, key: String) -> [String: ResumeEntry] {
        guard let data = defaults.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: ResumeEntry].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(allRaw) {
            defaults.set(data, forKey: key)
        }
    }

    /// All entries that survive the "barely started / nearly finished" prune,
    /// sorted by `at` descending (newest resumed first).
    var visible: [(vpath: String, entry: ResumeEntry)] {
        allRaw
            .filter { _, e in
                e.dur > 0 && e.pos >= 5 && e.pos <= e.dur * 0.95
            }
            .map { ($0.key, $0.value) }
            .sorted { $0.1.at > $1.1.at }
    }

    func get(_ vpath: String) -> ResumeEntry? { allRaw[vpath] }

    func update(vpath: String, pos: Double, dur: Double) {
        // Mirror web behavior: clear automatically when we're past the 95% line.
        if dur > 0 && pos > dur * 0.95 {
            remove(vpath)
            return
        }
        guard pos >= 0, dur >= 0 else { return }
        allRaw[vpath] = ResumeEntry(pos: pos, dur: dur, at: Date().timeIntervalSince1970)
        persist()
    }

    func remove(_ vpath: String) {
        if allRaw.removeValue(forKey: vpath) != nil {
            persist()
        }
    }

    func forgetAll() {
        allRaw.removeAll()
        persist()
    }

    var count: Int { visible.count }
}
