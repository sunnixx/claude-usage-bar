import Foundation
import Testing
@testable import ClaudeUsageCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct StubCodexTokens: CodexTokenProviding {
    let result: Result<CodexTokenLookup, TokenStoreError>
    func credentials() throws -> CodexTokenLookup { try result.get() }
}

private let signedIn = StubCodexTokens(
    result: .success(.credentials(CodexCredentials(accessToken: "sk-codex-abc", accountId: "acc-1")))
)

private func respond(_ status: Int, _ body: Data) -> UsageClient.Transport {
    { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

@Suite struct CodexClientTests {
    @Test func sendsTheRequiredHeaders() async throws {
        let captured = Captured()
        let client = CodexClient(tokens: signedIn, transport: { request in
            await captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (try Fixture.data("codex-free"), response)
        })

        _ = try await client.fetchUsage()
        let request = try #require(await captured.request)

        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-codex-abc")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acc-1")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == CodexClient.userAgent)
    }

    @Test func omitsTheAccountHeaderWhenThereIsNoAccountId() async throws {
        let captured = Captured()
        let tokens = StubCodexTokens(
            result: .success(.credentials(CodexCredentials(accessToken: "t", accountId: nil)))
        )
        let client = CodexClient(tokens: tokens, transport: { request in
            await captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (try Fixture.data("codex-free"), response)
        })

        _ = try await client.fetchUsage()
        #expect(try #require(await captured.request).value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    @Test func reportsAMissingToken() async {
        let client = CodexClient(
            tokens: StubCodexTokens(result: .success(.missing)),
            transport: respond(200, Data())
        )
        await #expect(throws: UsageError.noToken) { try await client.fetchUsage() }
    }

    @Test(arguments: [401, 403])
    func reportsAnExpiredToken(status: Int) async {
        let client = CodexClient(tokens: signedIn, transport: respond(status, Data()))
        await #expect(throws: UsageError.unauthorized) { try await client.fetchUsage() }
    }

    @Test func reportsUnexpectedStatusCodes() async {
        let client = CodexClient(tokens: signedIn, transport: respond(503, Data()))
        await #expect(throws: UsageError.badStatus(503)) { try await client.fetchUsage() }
    }

    @Test func reportsUndecodableBodies() async {
        let client = CodexClient(tokens: signedIn, transport: respond(200, Data("nope".utf8)))
        await #expect(throws: UsageError.decoding) { try await client.fetchUsage() }
    }

    @Test func treatsAThrownTokenStoreErrorAsUnavailable() async {
        let client = CodexClient(
            tokens: StubCodexTokens(result: .failure(.unreadable)),
            transport: respond(200, Data())
        )
        await #expect(throws: UsageError.tokenStoreUnavailable) { try await client.fetchUsage() }
    }

    @Test func decodesASuccessfulResponse() async throws {
        let client = CodexClient(tokens: signedIn, transport: { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (try Fixture.data("codex-free"), response)
        })

        let snapshot = try await client.fetchUsage()
        #expect(snapshot.provider == .codex)
        #expect(snapshot.primary?.label == "30 days")
    }
}

private actor Captured {
    private(set) var request: URLRequest?
    func set(_ request: URLRequest) { self.request = request }
}
