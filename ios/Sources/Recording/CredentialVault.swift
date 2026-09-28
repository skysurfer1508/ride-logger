import Foundation
import Security

/// What the recorder needs to upload without a browser session: the account's ingest token (the same one Overland uses) and the email of the
/// account it belongs to. Kept in the Keychain, readable once the phone has been unlocked after boot, because a ride keeps uploading while
/// the phone is locked in a pocket.
enum CredentialVault {
    struct Credentials: Codable, Equatable {
        var token: String
        var email: String
    }

    private static let service = "com.skyserver1508.ridelogger.ingest"
    private static let account = "credentials"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
