import Foundation

public enum UsageState: Equatable, Sendable {
    case loading
    case loaded(UsageSnapshot)
    case stale(UsageSnapshot, since: Date)
    case noToken
    case unauthorized
    case unreachable
    /// Keychain lookup failed (denied prompt, locked keychain, corrupt item)
    /// and there is no prior good value to fall back on.
    case keychainDenied

    /// The percentage shown in the menu bar, if there is one.
    public var displayPercent: Int? {
        switch self {
        case .loaded(let snapshot), .stale(let snapshot, _):
            return snapshot.session?.percent
        case .loading, .noToken, .unauthorized, .unreachable, .keychainDenied:
            return nil
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

    private var lastSnapshot: UsageSnapshot?

    /// Consecutive `.noToken` / `.unauthorized` results. Claude Code rotates
    /// the OAuth token roughly every 8 hours, rewriting the Keychain item; a
    /// poll landing in that window sends the superseded token and gets a 401,
    /// or reads the item mid-rewrite and finds nothing. Neither means the user
    /// signed out — the next poll reads the new token and succeeds. So a good
    /// value survives one auth failure and is dropped only once a second
    /// consecutive one confirms it.
    private var consecutiveAuthFailures = 0

    public init() {}

    public mutating func record(success snapshot: UsageSnapshot) {
        lastSnapshot = snapshot
        state = .loaded(snapshot)
        interval = Self.baseInterval
        consecutiveAuthFailures = 0
    }

    public mutating func record(failure: UsageError) {
        switch failure {
        case .noToken, .unauthorized:
            consecutiveAuthFailures += 1
        case .transport, .badStatus, .decoding, .keychainUnavailable:
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
                state = .stale(lastSnapshot, since: lastSnapshot.fetchedAt)
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
                state = .stale(lastSnapshot, since: lastSnapshot.fetchedAt)
            } else {
                state = .unreachable
            }
        case .keychainUnavailable:
            // A denied prompt or locked keychain is transient — never treat it
            // like a sign-out. Retain the last good value if there is one.
            if let lastSnapshot {
                state = .stale(lastSnapshot, since: lastSnapshot.fetchedAt)
            } else {
                state = .keychainDenied
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
