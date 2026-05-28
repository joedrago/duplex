import Foundation

// MARK: - Browse

struct BrowseResponse: Decodable {
    let path: String
    let entries: [Entry]
}

enum Entry: Decodable, Identifiable, Hashable {
    case dir(name: String, children: Int, mtime: Int64)
    case file(name: String, ext: String?, size: UInt64, mtime: Int64, codecHint: String?)

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

    private enum CodingKeys: String, CodingKey {
        case kind, name, children, mtime, ext, size, codec_hint
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
                         codecHint: try c.decodeIfPresent(String.self, forKey: .codec_hint))
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
    case file(name: String, vpath: String, mtime: Int64, size: UInt64)

    var id: String { vpath }

    var vpath: String {
        switch self {
        case .dir(_, let v, _, _): return v
        case .file(_, let v, _, _): return v
        }
    }

    var name: String {
        switch self {
        case .dir(let n, _, _, _): return n
        case .file(let n, _, _, _): return n
        }
    }

    var mtime: Int64 {
        switch self {
        case .dir(_, _, let m, _): return m
        case .file(_, _, let m, _): return m
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

// MARK: - Manifest

struct Manifest: Decodable {
    let path: String
    let size: UInt64
    let duration: Double?
    let container: String
    let rawURL: String
    let videoTracks: [VideoTrack]
    let audioTracks: [AudioTrack]
    let subtitleTracks: [SubtitleTrack]
    let sidecars: [SidecarEntry]

    enum CodingKeys: String, CodingKey {
        case path, size, duration, container
        case rawURL = "raw_url"
        case videoTracks = "video_tracks"
        case audioTracks = "audio_tracks"
        case subtitleTracks = "subtitle_tracks"
        case sidecars
    }
}

struct VideoTrack: Decodable, Hashable {
    let index: UInt32
    let codec: String?
    let codecString: String?
    let width: UInt32?
    let height: UInt32?
    let profile: String?
    let level: Int32?
    let pixFmt: String?
    let colorPrimaries: String?
    let colorTransfer: String?
    let colorSpace: String?
    let colorRange: String?

    enum CodingKeys: String, CodingKey {
        case index, codec, width, height, profile, level
        case codecString = "codec_string"
        case pixFmt = "pix_fmt"
        case colorPrimaries = "color_primaries"
        case colorTransfer = "color_transfer"
        case colorSpace = "color_space"
        case colorRange = "color_range"
    }
}

struct AudioTrack: Decodable, Hashable {
    let index: UInt32
    let codec: String?
    let codecString: String?
    let channels: UInt32?
    let channelLayout: String?
    let sampleRate: UInt32?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case index, codec, channels, language
        case codecString = "codec_string"
        case channelLayout = "channel_layout"
        case sampleRate = "sample_rate"
    }
}

struct SubtitleTrack: Decodable, Hashable {
    let index: UInt32
    let codec: String?
    let language: String?
    let format: String   // "text" | "image"
}

struct SidecarEntry: Decodable, Hashable, Identifiable {
    let index: Int
    let format: String
    let language: String?
    let url: String

    var id: Int { index }
}
