import Foundation

/// An explicit, intentional watch-queue. Unlike scattered "mark as watched"
/// flags, a Binge is a first-class object the user creates on purpose: a
/// flattened, ordered list of video vpaths to play in sequence. The front of
/// the queue (`vpaths[0]`) is always "what plays next"; finishing a video pops
/// it, and an empty queue deletes the binge.
struct Binge: Codable, Identifiable, Hashable {
    /// Stable identity — used for focus tracking and to bind playback to a
    /// specific binge across navigation.
    let id: String
    /// The folder the binge was created from, e.g. "TV/Favorite Show/S3".
    /// Doubles as the human label.
    let origin: String
    /// Ordered queue; `vpaths[0]` is the next video to play.
    var vpaths: [String]
    /// Unix seconds at creation — drives newest-first display order.
    let createdAt: Double

    /// The next video to play, or nil when the binge is exhausted.
    var front: String? { vpaths.first }
    var remaining: Int { vpaths.count }
}

/// A flattened folder awaiting the user's confirmation to become a binge.
/// Carries the data through the confirm dialog so `BingeStore.create` only
/// runs on "Yes".
struct PendingBinge: Identifiable {
    let id = UUID()
    let origin: String
    let vpaths: [String]
}

/// The single binge-related dialog a screen can be showing. Modeled as one
/// enum so each screen attaches exactly ONE `.alert` — multiple `.alert`
/// modifiers on the same view clobber each other on SwiftUI/tvOS, so a
/// per-purpose alert would silently fail to present.
enum BingeDialog: Identifiable {
    case confirmCreate(PendingBinge)
    case confirmDelete(Binge)
    case error(String)

    var id: String {
        switch self {
        case .confirmCreate(let p): return "create-\(p.id)"
        case .confirmDelete(let b): return "delete-\(b.id)"
        case .error(let m):         return "error-\(m)"
        }
    }
}

/// UserDefaults-backed list of binges, same persistence pattern as
/// `ResumeStore`. JSON-encoded under `duplex.binges`.
final class BingeStore: ObservableObject {
    static let shared = BingeStore()

    private let key = "duplex.binges"
    private let defaults = UserDefaults.standard
    @Published private(set) var all: [Binge] = []

    init() {
        self.all = Self.load(defaults: defaults, key: key)
    }

    private static func load(defaults: UserDefaults, key: String) -> [Binge] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Binge].self, from: data) else {
            return []
        }
        return list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    /// Binges in display order: newest first.
    var ordered: [Binge] {
        all.sorted { $0.createdAt > $1.createdAt }
    }

    func binge(id: String) -> Binge? { all.first { $0.id == id } }

    /// Every binge whose next-up video is exactly `vpath`. Powers the
    /// "is this the front of a binge?" interception when a video is played
    /// outside of a binge.
    func bingesWithFront(_ vpath: String) -> [Binge] {
        all.filter { $0.front == vpath }
    }

    @discardableResult
    func create(origin: String, vpaths: [String]) -> Binge? {
        guard !vpaths.isEmpty else { return nil }
        let binge = Binge(
            id: UUID().uuidString,
            origin: origin,
            vpaths: vpaths,
            createdAt: Date().timeIntervalSince1970
        )
        all.append(binge)
        persist()
        NSLog("[Duplex/Binge] created id=%@ origin=%@ count=%d", binge.id, origin, vpaths.count)
        return binge
    }

    /// Advance a binge past `vpath`, but only if `vpath` is still the front.
    /// The guard makes this idempotent — the end-of-playback and back-out
    /// hooks can both fire for the same video without double-popping. Removes
    /// the binge entirely once its queue empties.
    func popFrontIfMatches(id: String, vpath: String) {
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        guard all[idx].vpaths.first == vpath else { return }
        all[idx].vpaths.removeFirst()
        if all[idx].vpaths.isEmpty {
            NSLog("[Duplex/Binge] exhausted id=%@ — removing", id)
            all.remove(at: idx)
        } else {
            NSLog("[Duplex/Binge] popped id=%@ now front=%@ remaining=%d",
                  id, all[idx].vpaths.first ?? "(nil)", all[idx].vpaths.count)
        }
        persist()
    }

    func remove(id: String) {
        if let idx = all.firstIndex(where: { $0.id == id }) {
            all.remove(at: idx)
            persist()
            NSLog("[Duplex/Binge] deleted id=%@", id)
        }
    }
}
