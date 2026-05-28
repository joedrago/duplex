import Foundation

struct SubtitleCue: Hashable {
    let start: Double
    let end: Double
    let text: String
}

/// Sidecar subtitle parser. Sniffs format from the first non-empty lines —
/// VTT header / SubViewer info / ASS script-info / SRT timestamp — then
/// dispatches. Matches the heuristics in `web/player.js`.
enum SubtitleParser {
    static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Lop off a BOM if present.
        var src = normalized
        if src.hasPrefix("\u{FEFF}") { src.removeFirst() }

        let lower = src.lowercased()
        if lower.hasPrefix("webvtt") {
            return parseVTT(src)
        }
        if lower.contains("[script info]") || lower.contains("[v4+ styles]") || lower.contains("[v4 styles]") {
            return parseASS(src)
        }
        if lower.contains("[information]") {
            return parseSubViewer(src)
        }
        return parseSRT(src)
    }

    // MARK: VTT / SRT

    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"(\d+):(\d+):(\d+)[.,](\d{1,3})"#)

    private static func parseVTT(_ src: String) -> [SubtitleCue] {
        parseCueBlocks(in: src, arrow: "-->")
    }

    private static func parseSRT(_ src: String) -> [SubtitleCue] {
        parseCueBlocks(in: src, arrow: "-->")
    }

    private static func parseCueBlocks(in src: String, arrow: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        // Split into blocks separated by blank lines.
        let blocks = src.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { continue }
            // Find a line with the arrow.
            var arrowIdx = -1
            for (i, line) in lines.enumerated() {
                if line.contains(arrow) { arrowIdx = i; break }
            }
            guard arrowIdx >= 0 else { continue }
            let parts = lines[arrowIdx].components(separatedBy: arrow)
            guard parts.count == 2 else { continue }
            guard let start = parseTimestamp(parts[0]),
                  let end   = parseTimestamp(parts[1]) else { continue }
            let textLines = lines[(arrowIdx + 1)...].joined(separator: "\n")
            let clean = stripVTTTags(textLines).trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            cues.append(SubtitleCue(start: start, end: end, text: clean))
        }
        return cues
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let m = timestampRegex.firstMatch(in: trimmed, range: range) else { return nil }
        func g(_ i: Int) -> Double {
            guard let r = Range(m.range(at: i), in: trimmed) else { return 0 }
            return Double(trimmed[r]) ?? 0
        }
        let h = g(1), mm = g(2), s = g(3)
        var ms = g(4)
        // VTT spec uses 3 digits; pad if we got 1-2.
        let msStr = m.range(at: 4)
        if let r = Range(msStr, in: trimmed) {
            let raw = String(trimmed[r])
            if raw.count == 1 { ms *= 100 }
            else if raw.count == 2 { ms *= 10 }
        }
        return h * 3600 + mm * 60 + s + ms / 1000
    }

    private static func stripVTTTags(_ s: String) -> String {
        // <c.classname>foo</c>, <i>bar</i>, &amp; etc.
        var out = s
        out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        return out
    }

    // MARK: ASS / SSA (text-only; styling dropped — Phase 3 will add styled rendering)

    private static func parseASS(_ src: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false
        var format: [String] = []
        for line in src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if trimmed.lowercased().hasPrefix("format:") {
                let body = trimmed.dropFirst("format:".count)
                format = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                continue
            }
            if trimmed.lowercased().hasPrefix("dialogue:") {
                guard !format.isEmpty else { continue }
                let body = String(trimmed.dropFirst("dialogue:".count)).trimmingCharacters(in: .whitespaces)
                // Dialogue has format.count - 1 commas before the last field (Text).
                let pieces = body.split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false).map(String.init)
                guard pieces.count == format.count else { continue }
                var fields: [String: String] = [:]
                for (i, key) in format.enumerated() { fields[key] = pieces[i] }
                guard let startRaw = fields["Start"],
                      let endRaw = fields["End"],
                      let textRaw = fields["Text"] else { continue }
                guard let start = parseASSTime(startRaw),
                      let end = parseASSTime(endRaw) else { continue }
                let text = stripASS(textRaw)
                if text.isEmpty { continue }
                cues.append(SubtitleCue(start: start, end: end, text: text))
            }
        }
        return cues
    }

    private static func parseASSTime(_ raw: String) -> Double? {
        // ASS format: H:MM:SS.cs (centiseconds)
        let parts = raw.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]),
              let m = Double(parts[1]) else { return nil }
        let secParts = parts[2].split(separator: ".")
        guard let s = Double(secParts[0]) else { return nil }
        let cs = secParts.count > 1 ? (Double(secParts[1]) ?? 0) : 0
        return h * 3600 + m * 60 + s + cs / 100
    }

    private static func stripASS(_ raw: String) -> String {
        // Drop {\override} blocks and turn \N into newline.
        var s = raw.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: SubViewer 1/2

    private static func parseSubViewer(_ src: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            // Look for "HH:MM:SS.MS,HH:MM:SS.MS"
            if let commaIdx = trimmed.firstIndex(of: ","),
               let start = parseSubViewerTime(String(trimmed[..<commaIdx])),
               let end = parseSubViewerTime(String(trimmed[trimmed.index(after: commaIdx)...])) {
                let next = i + 1 < lines.count ? lines[i + 1] : ""
                let text = next.replacingOccurrences(of: "[br]", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    cues.append(SubtitleCue(start: start, end: end, text: text))
                }
                i += 2
            } else {
                i += 1
            }
        }
        return cues
    }

    private static func parseSubViewerTime(_ raw: String) -> Double? {
        let parts = raw.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]),
              let m = Double(parts[1]) else { return nil }
        let secParts = parts[2].split(separator: ".")
        guard let s = Double(secParts[0]) else { return nil }
        let ms = secParts.count > 1 ? (Double(secParts[1]) ?? 0) : 0
        return h * 3600 + m * 60 + s + ms / 100
    }
}

extension SubtitleParser {
    /// Find the active cue at `time` via binary search. Returns nil when no
    /// cue spans the requested time.
    static func activeCue(in cues: [SubtitleCue], at time: Double) -> SubtitleCue? {
        // cues are not guaranteed sorted in pathological inputs; assume sorted by start.
        var lo = 0, hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = cues[mid]
            if time < c.start { hi = mid - 1 }
            else if time > c.end { lo = mid + 1 }
            else { return c }
        }
        return nil
    }
}
