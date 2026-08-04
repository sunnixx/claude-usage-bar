import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct KeychainTokenStoreTests {
    @Test func extractsTheAccessToken() throws {
        let json = Data("""
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","expiresAt":1234567890}}
        """.utf8)

        #expect(try KeychainTokenStore.parseToken(from: json) == "sk-ant-oat01-abc")
    }

    @Test func rejectsJSONWithoutTheOAuthObject() {
        let json = Data(#"{"somethingElse":true}"#.utf8)

        #expect(throws: KeychainError.malformed) {
            try KeychainTokenStore.parseToken(from: json)
        }
    }

    @Test func rejectsAnEmptyToken() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)

        #expect(throws: KeychainError.malformed) {
            try KeychainTokenStore.parseToken(from: json)
        }
    }

    @Test func rejectsNonJSONData() {
        #expect(throws: KeychainError.malformed) {
            try KeychainTokenStore.parseToken(from: Data("not json".utf8))
        }
    }
}
