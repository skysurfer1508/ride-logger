import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(Int)
    case offline
    case decoding(String)
    /// A readable reason the server itself gave (a traffic source that is down), shown as it is.
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unauthorized: return "You've been signed out."
        case .server(let code) where code == 404 || code == 405:
            return "The server doesn't know this request (\(code)). If the app was just updated, the server needs the update and a restart too."
        case .server(let code): return "The server answered with an error (\(code))."
        case .offline: return "Can't reach the server. Check your connection and try again."
        case .decoding: return "The server sent something the app didn't understand. Updating the app may help."
        }
    }
}

/// Talks to /api/v1 with the site session cookie (URLSession.shared keeps the cookie AuthService stored).
final class APIClient: ObservableObject {
    /// Called on any 401: the session ended, the app goes back to the sign-in screen.
    var onUnauthorized: (() -> Void)?
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await getRaw(path, query: query)
        return try decode(data)
    }

    /// The raw JSON of a GET (the loaders keep it to show again while the next answer is on its way).
    func getRaw(_ path: String, query: [String: String] = [:]) async throws -> Data {
        var comps = URLComponents(url: Config.baseURL, resolvingAgainstBaseURL: false)!
        comps.path = "/api/v1/" + path
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: comps.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await sendRaw(request)
    }

    /// A change (form post). The server refuses these without the client header.
    func post<T: Decodable>(_ path: String, form: [String: String] = [:]) async throws -> T {
        var body = URLComponents()
        body.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: Config.baseURL.appendingPathComponent("api/v1/" + path))
        request.httpMethod = "POST"
        request.setValue(Config.clientHeaderValue, forHTTPHeaderField: Config.clientHeaderName)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        return try decode(try await sendRaw(request))
    }

    /// A delete (a ride). The server refuses these without the client header.
    func delete<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: Config.baseURL.appendingPathComponent("api/v1/" + path))
        request.httpMethod = "DELETE"
        request.setValue(Config.clientHeaderValue, forHTTPHeaderField: Config.clientHeaderName)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try decode(try await sendRaw(request))
    }

    /// A file download (a ride's GPX), saved to a temporary file named as the server suggests.
    func download(_ path: String) async throws -> URL {
        var comps = URLComponents(url: Config.baseURL, resolvingAgainstBaseURL: false)!
        comps.path = "/api/v1/" + path
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: comps.url!) } catch { throw APIError.offline }
        guard let http = response as? HTTPURLResponse else { throw APIError.server(0) }
        if http.statusCode == 401 {
            await MainActor.run { onUnauthorized?() }
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError.server(http.statusCode) }
        var name = "ride.gpx"
        if let disposition = http.value(forHTTPHeaderField: "Content-Disposition"), let range = disposition.range(of: "filename=\"") {
            let rest = disposition[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") { name = String(rest[..<end]) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        try data.write(to: file)
        return file
    }

    /// A file upload (multipart/form-data), e.g. a GPX file to import.
    func postFile<T: Decodable>(_ path: String, field: String, filename: String, mimeType: String, data fileData: Data) async throws -> T {
        let boundary = "RideLogBoundary-" + UUID().uuidString
        var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        let safeName = filename.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        add("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: Config.baseURL.appendingPathComponent("api/v1/" + path))
        request.httpMethod = "POST"
        request.setValue(Config.clientHeaderValue, forHTTPHeaderField: Config.clientHeaderName)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120
        return try decode(try await sendRaw(request))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder.ridelog.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            await MainActor.run { onUnauthorized?() }
            throw APIError.unauthorized
        }
        guard (200..<300).contains(status) else {
            if [400, 413, 502].contains(status), let text = Self.serviceMessage(in: data) { throw APIError.message(text) }
            throw APIError.server(status)
        }
        return data
    }

    /// `{"detail": {"detail": "traffic_unavailable", "message": "..."}}` from the traffic endpoints.
    static func serviceMessage(in data: Data) -> String? {
        struct Body: Decodable {
            struct Detail: Decodable { let message: String? }
            let detail: Detail?
        }
        return (try? JSONDecoder().decode(Body.self, from: data))?.detail?.message
    }
}
