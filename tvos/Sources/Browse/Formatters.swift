import Foundation

enum DuplexFormat {
    static func size(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// "just now", "2m ago", "3h ago", "5d ago", "Jan 12"
    static func relative(_ mtime: Int64) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(mtime))
        let interval = Date().timeIntervalSince(then)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        if interval < 86_400 * 30 { return "\(Int(interval / 86_400))d ago" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: then)
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    /// Last segment of a virtual path.
    static func leaf(of vpath: String) -> String {
        if let i = vpath.lastIndex(of: "/") {
            return String(vpath[vpath.index(after: i)...])
        }
        return vpath
    }

    /// Everything before the last slash, for showing context. Empty if none.
    static func parent(of vpath: String) -> String {
        if let i = vpath.lastIndex(of: "/") {
            return String(vpath[..<i])
        }
        return ""
    }
}
