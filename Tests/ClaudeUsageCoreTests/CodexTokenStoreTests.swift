import ClaudeUsageCore
import ClaudeUsageTokens
import Foundation
import Testing

@Suite struct CodexTokenStoreTests {
    private func tempFile(_ contents: String, function: String = #function) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(abs(function.hashValue))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("auth.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private let valid = """
        {"auth_mode":"chatgpt","tokens":{"access_token":"sk-codex-abc",\
        "account_id":"00000000-0000-0000-0000-000000000000","refresh_token":"r"}}
        """

    @Test func readsTheAccessTokenAndAccountId() throws {
        let store = CodexTokenStore(path: try tempFile(valid))
        let lookup = try store.credentials()

        guard case .credentials(let creds) = lookup else {
            Issue.record("expected credentials, got \(lookup)")
            return
        }
        #expect(creds.accessToken == "sk-codex-abc")
        #expect(creds.accountId == "00000000-0000-0000-0000-000000000000")
    }

    @Test func reportsMissingWhenTheFileIsAbsent() throws {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-codex-\(UUID().uuidString).json")
        #expect(try CodexTokenStore(path: absent).credentials() == .missing)
    }

    @Test func toleratesAMissingAccountId() throws {
        let store = CodexTokenStore(
            path: try tempFile(#"{"tokens":{"access_token":"sk-codex-abc"}}"#)
        )
        guard case .credentials(let creds) = try store.credentials() else {
            Issue.record("expected credentials")
            return
        }
        #expect(creds.accountId == nil)
    }

    @Test func throwsOnMalformedJSON() throws {
        let store = CodexTokenStore(path: try tempFile("{ not json"))
        #expect(throws: TokenStoreError.malformed) { try store.credentials() }
    }

    @Test func throwsWhenTheAccessTokenIsEmpty() throws {
        let store = CodexTokenStore(path: try tempFile(#"{"tokens":{"access_token":""}}"#))
        #expect(throws: TokenStoreError.malformed) { try store.credentials() }
    }

    @Test func honoursCodexHome() {
        let path = CodexTokenStore.defaultPath(
            environment: ["CODEX_HOME": "/custom/codex"],
            home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/custom/codex/auth.json")
    }

    @Test func fallsBackToTheHomeCodexDirectory() {
        let path = CodexTokenStore.defaultPath(
            environment: [:], home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/home/someone/.codex/auth.json")
    }
}
