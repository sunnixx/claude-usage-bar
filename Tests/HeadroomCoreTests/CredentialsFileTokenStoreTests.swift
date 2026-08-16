#if !os(macOS)
import HeadroomCore
import HeadroomTokens
import Foundation
import Testing

@Suite struct CredentialsFileTokenStoreTests {
    /// Writes `contents` to a unique temporary file and returns its URL.
    /// Test-only: the store itself never writes.
    private func tempFile(_ contents: String, function: String = #function) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cutb-\(abs(function.hashValue))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".credentials.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    @Test func readsTheAccessToken() throws {
        let file = try tempFile(#"{"claudeAiOauth":{"accessToken":"sk-abc"}}"#)
        let store = CredentialsFileTokenStore(path: file)
        #expect(try store.accessToken() == .token("sk-abc"))
    }

    @Test func reportsMissingWhenTheFileIsAbsent() throws {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).json")
        let store = CredentialsFileTokenStore(path: absent)
        // Not signed in is an expected state, not an error.
        #expect(try store.accessToken() == .missing)
    }

    @Test func throwsOnMalformedJSON() throws {
        let file = try tempFile("{ this is not json")
        let store = CredentialsFileTokenStore(path: file)
        #expect(throws: TokenStoreError.malformed) { try store.accessToken() }
    }

    @Test func throwsOnAnEmptyToken() throws {
        let file = try tempFile(#"{"claudeAiOauth":{"accessToken":""}}"#)
        let store = CredentialsFileTokenStore(path: file)
        #expect(throws: TokenStoreError.malformed) { try store.accessToken() }
    }

    @Test func throwsWhenTheOAuthKeyIsAbsent() throws {
        let file = try tempFile(#"{"other":{"accessToken":"sk-abc"}}"#)
        let store = CredentialsFileTokenStore(path: file)
        #expect(throws: TokenStoreError.malformed) { try store.accessToken() }
    }

    @Test func honoursClaudeConfigDir() {
        let path = CredentialsFileTokenStore.defaultPath(
            environment: ["CLAUDE_CONFIG_DIR": "/custom/dir"],
            home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/custom/dir/.credentials.json")
    }

    @Test func fallsBackToTheHomeClaudeDirectory() {
        let path = CredentialsFileTokenStore.defaultPath(
            environment: [:],
            home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/home/someone/.claude/.credentials.json")
    }

    @Test func ignoresAnEmptyClaudeConfigDir() {
        let path = CredentialsFileTokenStore.defaultPath(
            environment: ["CLAUDE_CONFIG_DIR": ""],
            home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/home/someone/.claude/.credentials.json")
    }
}
#endif
