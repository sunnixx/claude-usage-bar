import Foundation
import Testing
@testable import HeadroomCore

// URLRequest/HTTPURLResponse live in Foundation on Apple platforms and in
// FoundationNetworking on Linux and Windows.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct StubTokens: TokenProviding {
    let result: Result<TokenLookup, TokenStoreError>

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

        #expect(snapshot.primary?.percent == 37)
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
        // Pinned per-platform, not compared against UsageClient.userAgent
        // itself: that would be tautological (it would still pass if the
        // constant were "" or "junk") and would stop pinning what the header
        // actually says. UsageClient.userAgent reports whichever platform
        // this test is actually running on (F6 — it used to always say
        // "macOS", even on Linux and Windows), so the expectation must too.
        #if os(macOS)
        let expected = "headroom/1.0 (macOS)"
        #elseif os(Linux)
        let expected = "headroom/1.0 (Linux)"
        #elseif os(Windows)
        let expected = "headroom/1.0 (Windows)"
        #endif
        #expect(request.value(forHTTPHeaderField: "User-Agent") == expected)
    }

    @Test func reportsAMissingToken() async throws {
        await #expect(throws: UsageError.noToken) {
            try await client(tokens: StubTokens.missing, transport: respond(200, Data())).fetchUsage()
        }
    }

    @Test func treatsAThrownTokenStoreErrorAsUnavailableNotNoToken() async throws {
        await #expect(throws: UsageError.tokenStoreUnavailable) {
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
