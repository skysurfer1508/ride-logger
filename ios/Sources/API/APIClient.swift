import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(Int)
    case offline
    case decoding(String)

    var errorDescription: String? {
        switch self {
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
        guard (200..<300).contains(status) else { throw APIError.server(status) }
        return data
    }
}
