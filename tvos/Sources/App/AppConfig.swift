import Foundation

enum AppConfig {
    static let serverURLOverrideKey = "duplex.serverURL"

    static var buildTimeServerURL: String {
        Bundle.main.infoDictionary?["ServerURL"] as? String ?? "http://localhost:2345"
    }

    static var serverURL: URL {
        let raw = UserDefaults.standard.string(forKey: serverURLOverrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (raw?.isEmpty == false ? raw! : buildTimeServerURL)
        return URL(string: chosen) ?? URL(string: "http://localhost:2345")!
    }

    static func setServerURLOverride(_ value: String?) {
        let defaults = UserDefaults.standard
        if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            defaults.set(v, forKey: serverURLOverrideKey)
        } else {
            defaults.removeObject(forKey: serverURLOverrideKey)
        }
    }
}
