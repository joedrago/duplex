import Foundation
import SwiftUI

/// How entries are ordered within a view.
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

/// How entries are laid out: the classic vertical list, or a grid of 2:3
/// poster boxes.
enum LayoutMode: String, CaseIterable {
    case list
    case posters

    var label: String {
        switch self {
        case .list: return "List"
        case .posters: return "Posters"
        }
    }
}

/// The single "View" axis the user cycles with the Play/Pause remote button.
/// Folds the layout (List/Posters) and sort (Name/Recent) into one four-state
/// cycle:
///
///   List · Name → List · Recent → Posters · Name → Posters · Recent → (wrap)
///
/// Shared + persisted, so Browse, Home, and Search all agree and the choice
/// survives relaunch.
final class ViewPreference: ObservableObject {
    static let shared = ViewPreference()

    private let sortKey = "duplex.sort"
    private let layoutKey = "duplex.layout"
    private let defaults = UserDefaults.standard

    @Published var sort: SortMode {
        didSet { defaults.set(sort.rawValue, forKey: sortKey) }
    }
    @Published var layout: LayoutMode {
        didSet { defaults.set(layout.rawValue, forKey: layoutKey) }
    }

    init() {
        let rawSort = UserDefaults.standard.string(forKey: sortKey) ?? SortMode.name.rawValue
        self.sort = SortMode(rawValue: rawSort) ?? .name
        let rawLayout = UserDefaults.standard.string(forKey: layoutKey) ?? LayoutMode.list.rawValue
        self.layout = LayoutMode(rawValue: rawLayout) ?? .list
    }

    /// Advance one step through the four-state cycle. Sort flips first, and on
    /// every wrap of the sort it advances the layout — so the order is
    /// List·Name, List·Recent, Posters·Name, Posters·Recent, then back.
    func cycle() {
        switch (layout, sort) {
        case (.list, .name):       sort = .recent
        case (.list, .recent):     layout = .posters; sort = .name
        case (.posters, .name):    sort = .recent
        case (.posters, .recent):  layout = .list; sort = .name
        }
    }

    /// Footer label, e.g. "List · Name" or "Posters · Recent".
    var label: String { "\(layout.label) · \(sort.label)" }
}
