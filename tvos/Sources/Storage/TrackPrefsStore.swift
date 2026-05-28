import Foundation

struct TrackPrefs: Codable, Hashable {
    /// nil → no preference saved yet; otherwise the VLC track index the user
    /// last picked for this video.
    var audio: Int?
    /// nil → no preference saved; -1 → user explicitly chose "Off"; >=0 → the
    /// subtitle track index they picked.
    var sub: Int?
}

/// UserDefaults-backed map of vpath → TrackPrefs. Mirrors ResumeStore's shape.
final class TrackPrefsStore: ObservableObject {
    static let shared = TrackPrefsStore()

    private let key = "duplex.trackPrefs"
    private let defaults = UserDefaults.standard
    @Published private(set) var all: [String: TrackPrefs] = [:]

    init() {
        self.all = Self.load(defaults: defaults, key: key)
    }

    private static func load(defaults: UserDefaults, key: String) -> [String: TrackPrefs] {
        guard let data = defaults.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: TrackPrefs].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    func get(_ vpath: String) -> TrackPrefs? { all[vpath] }

    func setAudio(vpath: String, index: Int) {
        var prefs = all[vpath] ?? TrackPrefs()
        prefs.audio = index
        all[vpath] = prefs
        persist()
    }

    func setSubtitle(vpath: String, index: Int) {
        var prefs = all[vpath] ?? TrackPrefs()
        prefs.sub = index
        all[vpath] = prefs
        persist()
    }
}
