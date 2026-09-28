import Foundation
import SwiftUI

/// Loads one GET endpoint. The last good answer is kept on the phone: the screen shows it at once and refreshes quietly. If the refresh fails
/// while something is on screen, that stays visible and `staleMessage` says why, instead of the screen turning into an error.
@MainActor
final class Loader<T: Decodable>: ObservableObject {
    enum Phase {
        case loading
        case loaded(T)
        case failed(String)
    }

    @Published var phase: Phase = .loading
    @Published var staleMessage: String?
    private let api: APIClient
    private let path: String
    private let query: [String: String]
    private var cacheKey: String { ResponseCache.key(path: path, query: query) }

    init(api: APIClient, path: String, query: [String: String] = [:]) {
        self.api = api
        self.path = path
        self.query = query
    }

    var value: T? {
        if case .loaded(let v) = phase { return v }
        return nil
    }

    func loadIfNeeded() async {
        if case .loaded = phase { return }
        if let data = ResponseCache.load(key: cacheKey), let saved = try? JSONDecoder.ridelog.decode(T.self, from: data) {
            phase = .loaded(saved)
        }
        await refresh()
    }

    func refresh() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let data = try await api.getRaw(path, query: query)
            let value = try JSONDecoder.ridelog.decode(T.self, from: data)
            ResponseCache.store(data, key: cacheKey)
            phase = .loaded(value)
            staleMessage = nil
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            if case .loaded = phase {
                staleMessage = "Showing what was saved on this phone. " + message
            } else {
                phase = .failed(message)
            }
        }
    }
}
