import Foundation

public enum TokenLookup: Equatable, Sendable {
    case token(String)
    case missing
}

public protocol TokenProviding: Sendable {
    func accessToken() throws -> TokenLookup
}

/// Why a token store failed. Deliberately carries no token material.
public enum TokenStoreError: Error, Equatable {
    /// The payload was not the JSON shape we expect, or the token was empty.
    case malformed
    /// The store exists but could not be read (permissions, locked keychain).
    case unreadable
    /// A platform status code we don't model individually (OSStatus on macOS).
    case platform(Int32)
}

/// Claude Code stores the same JSON shape in the macOS Keychain and in
/// `.credentials.json` on Linux and Windows, so both stores share this parser.
public enum CredentialsJSON {
    public static func parseToken(from data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw TokenStoreError.malformed
        }
        return token
    }
}
