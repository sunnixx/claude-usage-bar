#if !os(macOS)
import HeadroomCore
import Foundation

/// Reads the OAuth token Claude Code writes to `.credentials.json` on Linux
/// (`~/.claude`, mode 0600) and Windows (`%USERPROFILE%\.claude`), or under
/// `$CLAUDE_CONFIG_DIR` when that is set.
///
/// This type never writes. Claude Code owns the credential and rotates it, and
/// unlike the macOS Keychain this is an ordinary file — a careless write would
/// corrupt it and break the user's CLI login. There is deliberately no code
/// path here that creates, truncates, or modifies the file.
public struct CredentialsFileTokenStore: TokenProviding {
    private let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init() {
        self.init(path: Self.defaultPath())
    }

    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        }
        return home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    public func accessToken() throws -> TokenLookup {
        guard FileManager.default.fileExists(atPath: path.path) else {
            // Claude Code is not signed in on this machine. An expected state,
            // not a failure.
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: path, options: [])
        } catch {
            // Present but unreadable — wrong owner, or mode stripped of read.
            throw TokenStoreError.unreadable
        }

        return .token(try CredentialsJSON.parseToken(from: data))
    }
}
#endif
