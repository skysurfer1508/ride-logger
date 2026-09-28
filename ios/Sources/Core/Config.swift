import Foundation

enum Config {
    /// From Config.xcconfig via Info.plist (key SiteHost).
    static let host: String = (Bundle.main.object(forInfoDictionaryKey: "SiteHost") as? String) ?? ""
    static var baseURL: URL { URL(string: "https://\(host)")! }
    /// The scheme the server redirects to after sign-in (app/routers/native_auth.py APP_SCHEME).
    static let callbackScheme = "ridelogger"
    /// The website's session cookie (app/main.py session_cookie).
    static let sessionCookieName = "ride_logger_session"
    /// Where the recorder uploads (app/routers/ingest.py), the same endpoint Overland uses.
    static let ingestPath = "/api/ingest"
    /// Required by the server on every request that changes something (app/auth.py require_api_client).
    static let clientHeaderName = "X-RideLog-Client"
    static let clientHeaderValue = "1"

    /// "1.0 (1)" for the About section.
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
