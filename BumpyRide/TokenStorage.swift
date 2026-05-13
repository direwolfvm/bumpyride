import Foundation
import Security

/// Keychain-backed storage for the bumpyride-web bearer token.
///
/// Layout:
///   `kSecClass`          → `kSecClassGenericPassword`
///   `kSecAttrService`    → `"me.bumpyride.web"` (per `IOS_INTEGRATION.md`)
///   `kSecAttrAccount`    → the user's email (returned by `/api/me`)
///   `kSecValueData`      → the raw token bytes (UTF-8 of the `br_…` string)
///   `kSecAttrAccessible` → `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
///
/// Using the email as the account attribute means the Keychain item self-describes
/// who it belongs to; loading returns the email alongside the token so we can show
/// "Connected as …" without a second round trip.  Only one connection is supported
/// at a time — saving replaces any previously stored item under the same service.
final class TokenStorage {
    let service: String

    init(service: String = "me.bumpyride.web") {
        self.service = service
    }

    struct Stored: Equatable {
        let token: String
        let email: String
    }

    enum StorageError: Error {
        case keychain(status: OSStatus)
        case malformed
    }

    /// Persist a token associated with the given email, atomically replacing any
    /// existing connection for this service.
    func save(token: String, email: String) throws {
        // Remove any existing item under this service, regardless of account.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StorageError.keychain(status: status)
        }
    }

    /// Return the stored credentials, or `nil` if nothing is saved.
    func load() -> Stored? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let dict = result as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let email = dict[kSecAttrAccount as String] as? String,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return Stored(token: token, email: email)
    }

    /// Remove the stored token (if any).  Safe to call when nothing is saved.
    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
