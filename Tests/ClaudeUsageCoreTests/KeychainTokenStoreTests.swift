import Foundation
import Testing
@testable import ClaudeUsageCore
import ClaudeUsageTokens

@Suite struct KeychainTokenStoreTests {
    @Test func extractsTheAccessToken() throws {
        let json = Data("""
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","expiresAt":1234567890}}
        """.utf8)

        #expect(try CredentialsJSON.parseToken(from: json) == "sk-ant-oat01-abc")
    }

    @Test func rejectsJSONWithoutTheOAuthObject() {
        let json = Data(#"{"somethingElse":true}"#.utf8)

        #expect(throws: TokenStoreError.malformed) {
            try CredentialsJSON.parseToken(from: json)
        }
    }

    @Test func rejectsAnEmptyTokenInARealisticKeychainPayload() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)

        #expect(throws: TokenStoreError.malformed) {
            try CredentialsJSON.parseToken(from: json)
        }
    }

    @Test func rejectsNonJSONData() {
        #expect(throws: TokenStoreError.malformed) {
            try CredentialsJSON.parseToken(from: Data("not json".utf8))
        }
    }

    @Test func parsesATokenFromCredentialsJSON() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"sk-test-123"}}"#.utf8)
        #expect(try CredentialsJSON.parseToken(from: data) == "sk-test-123")
    }

    @Test func rejectsAnEmptyToken() {
        let data = Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)
        #expect(throws: TokenStoreError.malformed) {
            try CredentialsJSON.parseToken(from: data)
        }
    }

    @Test func rejectsAMissingOAuthKey() {
        let data = Data(#"{"somethingElse":{}}"#.utf8)
        #expect(throws: TokenStoreError.malformed) {
            try CredentialsJSON.parseToken(from: data)
        }
    }

    @Test func rejectsNonJSON() {
        #expect(throws: TokenStoreError.malformed) {
            try CredentialsJSON.parseToken(from: Data("not json".utf8))
        }
    }
}
