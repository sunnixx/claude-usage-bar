import Foundation

public enum UsageState: Equatable, Sendable {
    case loading
    case loaded(ProviderSnapshot)
    case stale(ProviderSnapshot, since: Date, reason: StaleReason)
    case noToken
    case unauthorized
    case unreachable
    /// The token store threw (denied prompt, locked keychain, unreadable or
    /// malformed credentials file) and there is no prior good value to fall
    /// back on.
    case tokenStoreUnavailable

    /// The percentage shown in the menu bar, if there is one.
    public var displayPercent: Int? {
        switch self {
        case .loaded(let snapshot), .stale(let snapshot, _, _):
            return snapshot.primary?.percent
        case .loading, .noToken, .unauthorized, .unreachable, .tokenStoreUnavailable:
            return nil
        }
    }
}

/// Why a retained value is stale. The row says so, because "Offline" is wrong
/// when the app reached the server fine and was rate limited or sent something
/// it could not parse.
public enum StaleReason: Equatable, Sendable {
    case offline
    case rateLimited
    case serverError
    case badResponse
    case credentials

    public var rowText: String {
        switch self {
        case .offline: return "Offline"
        case .rateLimited: return "Rate limited"
        case .serverError: return "Server error"
        case .badResponse: return "Unexpected response"
        case .credentials: return "Can't read credentials"
        }
    }

    init(_ error: UsageError) {
        switch error {
        case .transport: self = .offline
        case .badStatus(429): self = .rateLimited
        case .badStatus: self = .serverError
        case .decoding: self = .badResponse
        case .tokenStoreUnavailable: self = .credentials
        // An unconfirmed auth failure is a rotation window, not a sign-out.
        case .noToken, .unauthorized: self = .credentials
        }
    }
}

/// Decides what to display and when to poll again.
///
/// A pure value type — it holds no timer and reads no clock, so the app can
/// drive it from a real loop while the tests drive it instantly.
public struct UsageRefreshPolicy: Equatable, Sendable {
    public static let baseInterval: TimeInterval = 60
    public static let maxInterval: TimeInterval = 300

    public private(set) var state: UsageState = .loading
    public private(set) var interval: TimeInterval = UsageRefreshPolicy.baseInterval

    private var lastSnapshot: ProviderSnapshot?

    /// Consecutive `.noToken` / `.unauthorized` results. Claude Code rotates
    /// the OAuth token roughly every 8 hours, rewriting the Keychain item; a
    /// poll landing in that window sends the superseded token and gets a 401,
    /// or reads the item mid-rewrite and finds nothing. Neither means the user
    /// signed out — the next poll reads the new token and succeeds. So a good
    /// value survives one auth failure and is dropped only once a second
    /// consecutive one confirms it.
    private var consecutiveAuthFailures = 0

    public init() {}

    public mutating func record(success snapshot: ProviderSnapshot) {
        lastSnapshot = snapshot
        state = .loaded(snapshot)
        interval = Self.baseInterval
        consecutiveAuthFailures = 0
    }

    public mutating func record(failure: UsageError) {
        switch failure {
        case .noToken, .unauthorized:
            consecutiveAuthFailures += 1
        case .transport, .badStatus, .decoding, .tokenStoreUnavailable:
            consecutiveAuthFailures = 0
        }

        // An unconfirmed auth failure keeps the base interval: the next poll is
        // the one that reads the rotated token, so deferring it would strand a
        // working app on an error for minutes.
        let isUnconfirmedAuthFailure = consecutiveAuthFailures == 1 && lastSnapshot != nil
        if !isUnconfirmedAuthFailure {
            interval = min(interval * 2, Self.maxInterval)
        }

        switch failure {
        case .noToken where isUnconfirmedAuthFailure,
             .unauthorized where isUnconfirmedAuthFailure:
            // Probably a rotation window. Hold the value; the next result decides.
            if let lastSnapshot {
                state = .stale(lastSnapshot, since: lastSnapshot.fetchedAt, reason: StaleReason(failure))
            }
        case .noToken:
            // Confirmed: signing out invalidates the number entirely — drop it
            // and prevent resurrection.
            lastSnapshot = nil
            state = .noToken
        case .unauthorized:
            // Confirmed: the token is genuinely dead, not merely superseded.
            lastSnapshot = nil
            state = .unauthorized
        case .transport, .badStatus, .decoding:
            if let lastSnapshot {
                state = .stale(lastSnapshot, since: lastSnapshot.fetchedAt, reason: StaleReason(failure))
            } else {
                state = .unreachable
            }
        case .tokenStoreUnavailable:
            // A denied prompt or locked keychain is transient — never treat it
            // like a sign-out. Retain the last good value if there is one.
            if let lastSnapshot {
                state = .stale(lastSnapshot, since: lastSnapshot.fetchedAt, reason: StaleReason(failure))
            } else {
                state = .tokenStoreUnavailable
            }
        }
    }

    /// Resets the backoff to the base interval without touching `state`.
    /// Call this from user-initiated refresh paths (Refresh Now, menu-open)
    /// so a manual retry doesn't inherit a backed-off interval. Never call
    /// this from the poll loop itself.
    public mutating func forceRefreshRequested() {
        interval = Self.baseInterval
    }
}
