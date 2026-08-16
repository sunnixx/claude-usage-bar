import HeadroomCore
import Foundation

/// Reads the OAuth token set the Codex CLI writes to `~/.codex/auth.json`
/// (mode 0600), or under `$CODEX_HOME` when that is set. Unlike Claude, Codex
/// uses a file on every platform, so there is no Keychain path here.
///
/// This type never writes. Codex owns the credential and rotates it — the file
/// carries `refresh_token` and `last_refresh` — so there is deliberately no code
/// path here that creates, truncates or modifies it.
public struct CodexTokenStore: CodexTokenProviding {
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
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("auth.json")
        }
        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    public func credentials() throws -> CodexTokenLookup {
        guard FileManager.default.fileExists(atPath: path.path) else {
            // Codex is not signed in on this machine. An expected state.
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: path, options: [])
        } catch {
            throw TokenStoreError.unreadable
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String,
            !token.isEmpty
        else {
            throw TokenStoreError.malformed
        }

        return .credentials(CodexCredentials(
            accessToken: token,
            accountId: tokens["account_id"] as? String
        ))
    }
}
