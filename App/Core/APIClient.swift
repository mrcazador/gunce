import Foundation

struct APIError: LocalizedError {
    let status: Int
    let code: String
    let message: String?

    var errorDescription: String? {
        switch code {
        case "unauthorized": "Oturum sona erdi. Yeniden giriş yap."
        case "another_task_active": "Başka bir görev aktif. Önce onu park et."
        case "invalid_state": "Bu görev şu an bu işlemi desteklemiyor."
        case "task_not_found": "Görev bulunamadı."
        case "offline": "Sunucuya ulaşılamadı. Bağlantını kontrol et." + (message.map { " (\($0))" } ?? "")
        case "not_configured": "Sunucu adresi ayarlı değil."
        default: message ?? "Bir şeyler ters gitti (\(code))."
        }
    }
}

/// Thin JSON client for the PickUp Worker. See docs/API.md.
final class APIClient {
    let baseURL: URL
    var token: String?

    private let session: URLSession
    private let decoder = JSONCoding.decoder

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Reads `GunceAPIHost` from Info.plist (set from the GUNCE_API_HOST build setting).
    static func fromBundle() -> APIClient? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "GunceAPIHost") as? String,
              !host.isEmpty, !host.contains("$("),
              let url = URL(string: "https://\(host)")
        else { return nil }
        return APIClient(baseURL: url)
    }

    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        as type: T.Type
    ) async throws -> T {
        let data = try await perform(method, path, query: query, body: body)
        return try decoder.decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        _ = try await perform(method, path, query: [], body: body)
    }

    private func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: [String: Any]?
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw APIError(status: 0, code: "bad_url", message: nil)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let result = try await load(req)
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? decoder.decode(APIErrorBody.self, from: data)
            throw APIError(status: status, code: body?.error ?? "http_\(status)", message: body?.message)
        }
        return data
    }
}

extension APIClient {
    /// Runs the request, retrying once when a connection dropped before an answer came back
    /// (common right after the app returns from the background or a system alert). Requests
    /// that create something are retried only when they surely never reached the server.
    fileprivate func load(_ req: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await session.data(for: req)
            } catch {
                // A cancelled request is not a connection problem; callers drop it silently.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                let code = (error as? URLError)?.code
                if attempt == 1, let code, Self.retryable(code, method: req.httpMethod ?? "GET") {
                    try await Task.sleep(for: .milliseconds(400))
                    continue
                }
                // The code tells "no internet" (-1009) from "host unreachable" (-1004) or a dropped
                // connection (-1005) when the person reports the error.
                // The endpoint says which request stalled when the person reports it.
                let what = "\(req.httpMethod ?? "GET") /\(req.url?.path.split(separator: "/").prefix(2).joined(separator: "/") ?? "")"
                throw APIError(status: 0, code: "offline", message: [code.map { "kod \($0.rawValue)" }, what].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    private static func retryable(_ code: URLError.Code, method: String) -> Bool {
        let neverSent: Set<URLError.Code> = [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]
        if neverSent.contains(code) { return true }
        let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .secureConnectionFailed]
        return transient.contains(code) && method != "POST"
    }
}

/// One line of the connection test in Settings.
struct ConnectionCheck: Identifiable {
    let id = UUID()
    let name: String
    let ok: Bool
    let detail: String
}

extension APIClient {
    /// Runs the requests the app depends on, one by one, on the app's own connection and on a
    /// fresh one, and reports time, HTTP version and status, so a stalled request can be named.
    func checkConnection() async -> [ConnectionCheck] {
        let since = JSONCoding.formatDate(.now)
        let steps: [(String, String, [URLQueryItem], Bool)] = [
            ("Sunucu", "health", [], false),
            ("Hesap", "v1/me", [], true),
            ("Eşitleme", "v1/sync", [URLQueryItem(name: "since", value: since)], true),
        ]
        var results: [ConnectionCheck] = []
        for (name, path, query, authed) in steps {
            results.append(await probe(name, path, query: query, authed: authed, session: session))
        }
        let fresh = URLSession(configuration: .ephemeral)
        results.append(await probe("Yeni bağlantı", "v1/me", query: [], authed: true, session: fresh))
        fresh.finishTasksAndInvalidate()
        return results
    }

    private func probe(_ name: String, _ path: String, query: [URLQueryItem], authed: Bool, session: URLSession) async -> ConnectionCheck {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { return ConnectionCheck(name: name, ok: false, detail: "adres hatalı") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authed, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let metrics = MetricsCollector()
        let started = Date.now
        do {
            let (_, response) = try await session.data(for: req, delegate: metrics)
            let ms = Int(Date.now.timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ConnectionCheck(
                name: name,
                ok: (200..<300).contains(status),
                detail: "\(status) · \(ms) ms · \(metrics.protocolName)"
            )
        } catch {
            let seconds = Int(Date.now.timeIntervalSince(started))
            let code = (error as? URLError)?.code.rawValue ?? 0
            return ConnectionCheck(name: name, ok: false, detail: "kod \(code) · \(seconds) sn · \(metrics.protocolName)")
        }
    }
}

/// Records which HTTP version a request used (h2, h3 or http/1.1).
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var protocolName = "?"

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        protocolName = metrics.transactionMetrics.last?.networkProtocolName ?? "?"
    }
}

/// Shared JSON settings: snake_case keys and ISO 8601 dates with milliseconds.
enum JSONCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(raw)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return e
    }()

    static func parseDate(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle())
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// A JSON value for an optional date: an ISO string, or null to clear the field.
    static func value(_ date: Date?) -> Any {
        date.map(formatDate) ?? NSNull()
    }

    /// A JSON value for an optional string: trimmed text, or null when empty.
    static func value(_ text: String?) -> Any {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? NSNull() : trimmed
    }
}
