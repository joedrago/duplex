import Foundation
import SwiftUI

enum SortMode: String, CaseIterable {
    case name
    case recent

    var label: String {
        switch self {
        case .name: return "Name"
        case .recent: return "Recent"
        }
    }
}

final class SortPreference: ObservableObject {
    static let shared = SortPreference()
    private let key = "duplex.sort"
    private let defaults = UserDefaults.standard

    @Published var mode: SortMode {
        didSet { defaults.set(mode.rawValue, forKey: key) }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "duplex.sort") ?? SortMode.name.rawValue
        self.mode = SortMode(rawValue: raw) ?? .name
    }

    func toggle() {
        mode = (mode == .name) ? .recent : .name
    }
}
