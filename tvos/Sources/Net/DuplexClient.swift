import Foundation

enum DuplexClientError: Error, LocalizedError {
    case http(Int, String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .decoding(let e): return "decode failed: \(e.localizedDescription)"
        case .transport(let e): return e.localizedDescription
        }
    }
}

struct DuplexClient {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = AppConfig.serverURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: URL builders

    /// `/api/browse?path=<vpath>` — empty path means root.
    func browse(path: String) async throws -> BrowseResponse {
        try await getJSON("/api/browse", query: ["path": path])
    }

    /// `/api/recent?limit=N`
    func recent(limit: Int = 30) async throws -> RecentResponse {
        try await getJSON("/api/recent", query: ["limit": String(limit)])
    }

    /// `/api/manifest?path=<vpath>`
    func manifest(path: String) async throws -> Manifest {
        try await getJSON("/api/manifest", query: ["path": path])
    }

    /// `/api/next?path=<vpath>` — nil when 404 (no next file).
    func next(path: String) async throws -> NextResponse? {
        do {
            let r: NextResponse = try await getJSON("/api/next", query: ["path": path])
            return r
        } catch DuplexClientError.http(404, _) {
            return nil
        }
    }

    /// `/api/search?q=<query>&limit=N` — case-insensitive substring search
    /// across every entry. Empty `query` returns no results without round-
    /// tripping to the server.
    func search(query: String, limit: Int = 50) async throws -> SearchResponse {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchResponse(items: []) }
        return try await getJSON("/api/search", query: ["q": q, "limit": String(limit)])
    }

    func rawURL(path: String) -> URL {
        url("/api/raw", query: ["path": path])
    }

    func sidecarURL(path: String, index: Int) -> URL {
        url("/api/sidecar", query: ["path": path, "index": String(index)])
    }

    // MARK: internals

    private func url(_ pathComponent: String, query: [String: String]) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(pathComponent),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url!
    }

    private func getJSON<T: Decodable>(_ pathComponent: String, query: [String: String]) async throws -> T {
        let req = URLRequest(url: url(pathComponent, query: query),
                             cachePolicy: .reloadIgnoringLocalCacheData)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw DuplexClientError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw DuplexClientError.http(-1, "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DuplexClientError.http(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DuplexClientError.decoding(error)
        }
    }
}
