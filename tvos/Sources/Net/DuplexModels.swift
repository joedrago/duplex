import Foundation

// MARK: - Browse

struct BrowseResponse: Decodable {
    let path: String
    let entries: [Entry]
}

enum Entry: Decodable, Identifiable, Hashable {
    case dir(name: String, children: Int, mtime: Int64)
    case file(name: String, ext: String?, size: UInt64, mtime: Int64, poster: Bool)

    var id: String { name }

    var name: String {
        switch self {
        case .dir(let n, _, _): return n
        case .file(let n, _, _, _, _): return n
        }
    }

    var mtime: Int64 {
        switch self {
        case .dir(_, _, let m): return m
        case .file(_, _, _, let m, _): return m
        }
    }

    var isDir: Bool {
        if case .dir = self { return true }
        return false
    }

    /// Whether a sidecar poster image is available for this file (always false
    /// for directories).
    var hasPoster: Bool {
        if case .file(_, _, _, _, let poster) = self { return poster }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case kind, name, children, mtime, ext, size, poster
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let name = try c.decode(String.self, forKey: .name)
        let mtime = try c.decode(Int64.self, forKey: .mtime)
        switch kind {
        case "dir":
            self = .dir(name: name,
                        children: try c.decode(Int.self, forKey: .children),
                        mtime: mtime)
        case "file":
            self = .file(name: name,
                         ext: try c.decodeIfPresent(String.self, forKey: .ext),
                         size: try c.decode(UInt64.self, forKey: .size),
                         mtime: mtime,
                         poster: try c.decodeIfPresent(Bool.self, forKey: .poster) ?? false)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown kind \(kind)")
        }
    }
}

// MARK: - Recent

struct RecentResponse: Decodable {
    let items: [RecentItem]
}

enum RecentItem: Decodable, Identifiable, Hashable {
    case dir(name: String, vpath: String, mtime: Int64, children: Int)
    case file(name: String, vpath: String, mtime: Int64, size: UInt64, poster: Bool)

    var id: String { vpath }

    var vpath: String {
        switch self {
        case .dir(_, let v, _, _): return v
        case .file(_, let v, _, _, _): return v
        }
    }

    var name: String {
        switch self {
        case .dir(let n, _, _, _): return n
        case .file(let n, _, _, _, _): return n
        }
    }

    var mtime: Int64 {
        switch self {
        case .dir(_, _, let m, _): return m
        case .file(_, _, let m, _, _): return m
        }
    }

    var isDir: Bool {
        if case .dir = self { return true }
        return false
    }

    /// Whether a sidecar poster image is available for this file (always false
    /// for directories).
    var hasPoster: Bool {
        if case .file(_, _, _, _, let poster) = self { return poster }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case kind, name, vpath, mtime, children, size, poster
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let name = try c.decode(String.self, forKey: .name)
        let vpath = try c.decode(String.self, forKey: .vpath)
        let mtime = try c.decode(Int64.self, forKey: .mtime)
        switch kind {
        case "dir":
            self = .dir(name: name, vpath: vpath, mtime: mtime,
                        children: try c.decode(Int.self, forKey: .children))
        case "file":
            self = .file(name: name, vpath: vpath, mtime: mtime,
                         size: try c.decode(UInt64.self, forKey: .size),
                         poster: try c.decodeIfPresent(Bool.self, forKey: .poster) ?? false)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown kind \(kind)")
        }
    }
}

// MARK: - Search

struct SearchResponse: Decodable {
    let items: [SearchItem]
}

/// A search hit. Shares the `RecentItem` shape on purpose so the same row
/// rendering logic can drive both views.
enum SearchItem: Decodable, Identifiable, Hashable {
    case dir(name: String, vpath: String, mtime: Int64, children: Int)
    case file(name: String, vpath: String, mtime: Int64, size: UInt64)

    var id: String { vpath }

    var vpath: String {
        switch self {
        case .dir(_, let v, _, _):  return v
        case .file(_, let v, _, _): return v
        }
    }

    var name: String {
        switch self {
        case .dir(let n, _, _, _):  return n
        case .file(let n, _, _, _): return n
        }
    }

    var isDir: Bool {
        if case .dir = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case kind, name, vpath, mtime, children, size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let name = try c.decode(String.self, forKey: .name)
        let vpath = try c.decode(String.self, forKey: .vpath)
        let mtime = try c.decode(Int64.self, forKey: .mtime)
        switch kind {
        case "dir":
            self = .dir(name: name, vpath: vpath, mtime: mtime,
                        children: try c.decode(Int.self, forKey: .children))
        case "file":
            self = .file(name: name, vpath: vpath, mtime: mtime,
                         size: try c.decode(UInt64.self, forKey: .size))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown kind \(kind)")
        }
    }
}

// MARK: - Next

struct NextResponse: Decodable {
    let name: String
    let vpath: String
    let mtime: Int64
}

// MARK: - Flatten

/// Depth-first, name-sorted list of every video vpath beneath a directory.
/// Taken verbatim as a binge's ordered queue.
struct FlattenResponse: Decodable {
    let origin: String
    let vpaths: [String]
}

// MARK: - House Party

/// The shared "fake player" state from `/api/houseparty`. `active == false`
/// means the party is idle (nothing playing); the other fields are then zeroed.
struct HousePartyState: Decodable, Equatable {
    let active: Bool
    let vpath: String?
    let duration: Double
    let position: Double
    let playing: Bool

    static let idle = HousePartyState(active: false, vpath: nil, duration: 0, position: 0, playing: false)
}

// MARK: - Manifest

// The server no longer probes files, so the manifest carries only what it can
// know without decoding: path, size, the raw URL, and the scan-derived sidecar
// list. Track/codec selection is handled by VLCKit reading the file itself
// (see PlayerView's `ingestTracks`), so we don't model embedded tracks here.
struct Manifest: Decodable {
    let path: String
    let size: UInt64
    let rawURL: String
    let sidecars: [SidecarEntry]

    enum CodingKeys: String, CodingKey {
        case path, size
        case rawURL = "raw_url"
        case sidecars
    }
}

struct SidecarEntry: Decodable, Hashable, Identifiable {
    let index: Int
    let format: String
    let language: String?
    let url: String

    var id: Int { index }
}
