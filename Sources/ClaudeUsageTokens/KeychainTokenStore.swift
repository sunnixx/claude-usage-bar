#if os(macOS)
import ClaudeUsageCore
import Foundation
import Security

/// Reads the OAuth token Claude Code stores in the login Keychain.
///
/// This type never writes. Claude Code owns the token and rotates it; a second
/// process attempting a refresh could invalidate the running CLI session.
public struct KeychainTokenStore: TokenProviding {
    public static let defaultService = "Claude Code-credentials"

    private let service: String

    public init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    public func accessToken() throws -> TokenLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw TokenStoreError.malformed }
            return .token(try CredentialsJSON.parseToken(from: data))
        case errSecItemNotFound:
            // Claude Code is not signed in on this machine. An expected state,
            // not a failure.
            return .missing
        default:
            throw TokenStoreError.platform(status)
        }
    }
}
#endif
