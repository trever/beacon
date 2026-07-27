import Foundation
import Security

// Keychain access for Sonos (design 2026-07-26-sonos-now-playing-plan). Split the same way ClaudeKeychain
// is: the privileged SecItem calls live here in the executable, the JSON shape they carry is parsed by
// the Foundation-only, host-tested ProviderCredentials.parseSonos/sonosBlob. Two separate items:
//   - the client secret, written ONCE by `set-sonos-secret` (stdin only -- see main.swift) and read back
//     only to build the OAuth Basic-auth header. Never logged, never echoed beyond a character count.
//   - the OAuth token cache, written by `sonos-authorize` and rewritten in place by SonosProvider's
//     refresh path. Unlike Claude there is no separate CLI racing this item -- beacon-hub is its sole
//     owner, so there is no read-only/preferred(cli:beacon:) split to worry about.
enum SonosKeychain {
    private static let secretService = "com.beacon.hub.sonos-secret"
    private static let secretAccount = "client-secret"
    private static let oauthService = "com.beacon.hub.sonos-oauth"
    private static let oauthAccount = "oauth"

    // --- client secret ---

    static func readSecret() -> String? {
        read(service: secretService, account: secretAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func writeSecret(_ secret: String) -> Bool {
        write(service: secretService, account: secretAccount, data: Data(secret.utf8))
    }

    // --- OAuth token cache ---

    static func readOAuthBlob() -> Data? { read(service: oauthService, account: oauthAccount) }

    @discardableResult
    static func writeOAuthBlob(_ blob: Data) -> Bool {
        write(service: oauthService, account: oauthAccount, data: blob)
    }

    // --- shared SecItem plumbing (mirrors ClaudeKeychain) ---

    private static func write(service: String, account: String, data: Data) -> Bool {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
    }

    private static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data
        else { return nil }
        return data
    }
}
