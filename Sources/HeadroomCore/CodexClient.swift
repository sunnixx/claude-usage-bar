import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches ChatGPT Codex usage.
///
/// Codex normally surfaces rate limits as response headers on ordinary API
/// calls, which would cost quota to read. This endpoint returns the same data
/// on a plain GET. It is undocumented and can change without notice, so the
/// decoder fails cleanly rather than crashing.
public struct CodexClient: UsageFetching {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static var userAgent: String { UsageClient.userAgent }

    private let tokens: any CodexTokenProviding
    private let now: @Sendable () -> Date
    private let transport: UsageClient.Transport

    public init(
        tokens: any CodexTokenProviding,
        now: @escaping @Sendable () -> Date = Date.init,
        transport: @escaping UsageClient.Transport = UsageClient.urlSessionTransport
    ) {
        self.tokens = tokens
        self.now = now
        self.transport = transport
    }

    public func fetchUsage() async throws -> ProviderSnapshot {
        let lookup: CodexTokenLookup
        do {
            lookup = try tokens.credentials()
        } catch {
            throw UsageError.tokenStoreUnavailable
        }

        guard case .credentials(let credentials) = lookup else {
            throw UsageError.noToken
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw UsageError.transport
        }

        switch response.statusCode {
        case 200: break
        case 401, 403: throw UsageError.unauthorized
        default: throw UsageError.badStatus(response.statusCode)
        }

        do {
            return try CodexSnapshot.decode(from: data, fetchedAt: now())
        } catch {
            throw UsageError.decoding
        }
    }
}
