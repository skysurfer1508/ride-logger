import CryptoKit
import Foundation
import Security

/// The proof-of-possession half of the sign-in handshake (see app/routers/native_auth.py on the server).
enum PKCE {
    /// 32 random bytes as base64url: 43 characters, inside the server's accepted 43...128.
    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no secure random bytes")
        return Logic.base64url(Data(bytes))
    }

    /// base64url(sha256(verifier)): what the server stores until the exchange.
    static func challenge(for verifier: String) -> String {
        Logic.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}
