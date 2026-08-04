import Foundation
import Testing
@testable import ClaudeUsageCore

private struct StubTokens: TokenProviding {
    let result: Result<TokenLookup, KeychainError>

    static let valid = StubTokens(result: .success(.token("sk-ant-oat01-test")))
    static let missing = StubTokens(result: .success(.missing))
    static let broken = StubTokens(result: .failure(.malformed))

    func accessToken() throws -> TokenLookup { try result.get() }
}

private func respond(_ status: Int, _ body: Data) -> UsageClient.Transport {
    { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

@Suite struct UsageClientTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_000_000)

    private func client(
        tokens: any TokenProviding = StubTokens.valid,
        transport: @escaping UsageClient.Transport
    ) -> UsageClient {
        UsageClient(tokens: tokens, now: { self.fetchedAt }, transport: transport)
    }

    @Test func decodesASuccessfulResponse() async throws {
        let body = try Fixture.data("full")
        let snapshot = try await client(transport: respond(200, body)).fetchUsage()

        #expect(snapshot.session?.percent == 37)
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func sendsTheRequiredHeaders() async throws {
        let body = try Fixture.data("full")
        let captured = Captured()

        let transport: UsageClient.Transport = { request in
            await captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }

        _ = try await client(transport: transport).fetchUsage()
        let request = try #require(await captured.request)

        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-usage-bar/1.0 (macOS)")
    }

    @Test func reportsAMissingToken() async throws {
        await #expect(throws: UsageError.noToken) {
            try await client(tokens: StubTokens.missing, transport: respond(200, Data())).fetchUsage()
        }
    }

    @Test func treatsAThrownKeychainErrorAsUnavailableNotNoToken() async throws {
        await #expect(throws: UsageError.keychainUnavailable) {
            try await client(tokens: StubTokens.broken, transport: respond(200, Data())).fetchUsage()
        }
    }

    @Test(arguments: [401, 403])
    func reportsAnExpiredToken(status: Int) async throws {
        await #expect(throws: UsageError.unauthorized) {
            try await client(transport: respond(status, Data())).fetchUsage()
        }
    }

    @Test func reportsUnexpectedStatusCodes() async throws {
        await #expect(throws: UsageError.badStatus(503)) {
            try await client(transport: respond(503, Data())).fetchUsage()
        }
    }

    @Test func reportsTransportFailures() async throws {
        let transport: UsageClient.Transport = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await #expect(throws: UsageError.transport) {
            try await client(transport: transport).fetchUsage()
        }
    }

    @Test func reportsUndecodableBodies() async throws {
        await #expect(throws: UsageError.decoding) {
            try await client(transport: respond(200, Data("{nope".utf8))).fetchUsage()
        }
    }
}

private actor Captured {
    private(set) var request: URLRequest?
    func set(_ request: URLRequest) { self.request = request }
}
