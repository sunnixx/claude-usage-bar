import Foundation

// URLSession lives in Foundation on Apple platforms and in FoundationNetworking
// on Linux and Windows.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum UsageError: Error, Equatable {
    case noToken
    case unauthorized
    case transport
    case badStatus(Int)
    case decoding
    /// The token store threw (denied prompt, locked keychain, unreadable or
    /// malformed credentials file) — distinct from `.noToken`, which means the
    /// lookup succeeded and found nothing. Treated as transient so a good value
    /// is never blanked.
    case tokenStoreUnavailable
}

public protocol UsageFetching: Sendable {
    func fetchUsage() async throws -> ProviderSnapshot
}

public struct UsageClient: UsageFetching {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let userAgent = "claude-usage-bar/1.0 (\(platformName))"

    private static var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #elseif os(Windows)
        return "Windows"
        #else
        return "unknown"
        #endif
    }

    public static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.transport }
        return (data, http)
    }

    private let tokens: any TokenProviding
    private let now: @Sendable () -> Date
    private let transport: Transport

    public init(
        tokens: any TokenProviding,
        now: @escaping @Sendable () -> Date = Date.init,
        transport: @escaping Transport = UsageClient.urlSessionTransport
    ) {
        self.tokens = tokens
        self.now = now
        self.transport = transport
    }

    public func fetchUsage() async throws -> ProviderSnapshot {
        let lookup: TokenLookup
        do {
            lookup = try tokens.accessToken()
        } catch {
            throw UsageError.tokenStoreUnavailable
        }

        guard case .token(let token) = lookup else {
            throw UsageError.noToken
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
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
        case 200:
            break
        case 401, 403:
            throw UsageError.unauthorized
        default:
            throw UsageError.badStatus(response.statusCode)
        }

        do {
            return try UsageSnapshot.decode(from: data, fetchedAt: now())
        } catch {
            throw UsageError.decoding
        }
    }
}
