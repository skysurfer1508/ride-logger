import AuthenticationServices
import SwiftUI

/// Sign-in state and the handshake with the server (app/routers/native_auth.py): the system sign-in sheet
/// (ASWebAuthenticationSession) runs Authentik, the server hands back a one-time code on ridelogger://auth,
/// and the app swaps it (with the PKCE verifier) for the normal site session cookie, which every API call then carries
/// (URLSession keeps it in the shared cookie storage, which survives app restarts).
@MainActor
final class AuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    enum State { case checking, signedOut, signedIn }
    enum AuthError: Error { case noCode, exchangeFailed }

    @Published var state: State = .checking
    @Published var error: String?
    private var session: ASWebAuthenticationSession?

    /// Signed in if a session cookie for the site is already stored (it lasts 30 days on the server).
    /// If the server has ended it anyway, the first API call answers 401 and APIClient calls sessionEnded().
    func restore() async {
        let cookies = HTTPCookieStorage.shared.cookies(for: Config.baseURL) ?? []
        state = cookies.contains { $0.name == Config.sessionCookieName && ($0.expiresDate ?? .distantFuture) > Date() } ? .signedIn : .signedOut
    }

    func signIn() async {
        error = nil
        let verifier = PKCE.randomVerifier()
        var comps = URLComponents(url: Config.baseURL, resolvingAgainstBaseURL: false)!
        comps.path = "/app/login"
        comps.queryItems = [URLQueryItem(name: "challenge", value: PKCE.challenge(for: verifier))]
        do {
            let callback = try await authenticate(comps.url!)
            guard let code = Logic.code(fromCallback: callback) else { throw AuthError.noCode }
            try await exchange(code: code, verifier: verifier)
            state = .signedIn
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // the person closed the sheet: nothing to report
        } catch {
            self.error = "Sign-in didn't complete. Please try again."
        }
    }

    /// The server no longer accepts the cookie (expired, or the account was removed).
    func sessionEnded() {
        Task {
            await clearLocalSession()
            state = .signedOut
        }
    }

    func signOut() async {
        _ = try? await URLSession.shared.data(from: Config.baseURL.appendingPathComponent("logout"))
        await clearLocalSession()
        state = .signedOut
    }

    // MARK: - steps

    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Config.callbackScheme) { callback, err in
                if let callback { cont.resume(returning: callback) } else { cont.resume(throwing: err ?? AuthError.noCode) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false      // reuse the Authentik login already in Safari when there is one
            session = s
            if !s.start() { cont.resume(throwing: AuthError.noCode) }
        }
    }

    private func exchange(code: String, verifier: String) async throws {
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "verifier", value: verifier)]
        var request = URLRequest(url: Config.baseURL.appendingPathComponent("app/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw AuthError.exchangeFailed }
        // URLSession stored the Set-Cookie in the shared cookie storage; that is all the app needs.
        let cookies = HTTPCookieStorage.shared.cookies(for: Config.baseURL) ?? []
        guard cookies.contains(where: { $0.name == Config.sessionCookieName }) else { throw AuthError.exchangeFailed }
    }

    /// Forgets the site cookie and the saved screens (they belong to the person who just left). A ride being recorded is never touched here.
    private func clearLocalSession() async {
        ResponseCache.clear()
        if let stored = HTTPCookieStorage.shared.cookies(for: Config.baseURL) {
            for c in stored { HTTPCookieStorage.shared.deleteCookie(c) }
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
