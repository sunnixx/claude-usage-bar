import Foundation

public enum UsageState: Equatable, Sendable {
    case loading
    case loaded(UsageSnapshot)
    case stale(UsageSnapshot, since: Date)
    case noToken
    case unauthorized
    case unreachable

    /// The percentage shown in the menu bar, if there is one.
    public var displayPercent: Int? {
        switch self {
        case .loaded(let snapshot), .stale(let snapshot, _):
            return snapshot.session?.percent
        case .loading, .noToken, .unauthorized, .unreachable:
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

    public init() {}

    public mutating func record(success snapshot: UsageSnapshot) {
        lastSnapshot = snapshot
        state = .loaded(snapshot)
        interval = Self.baseInterval
    }

    public mutating func record(failure: UsageError) {
        interval = min(interval * 2, Self.maxInterval)

        switch failure {
        case .noToken:
            // Signing out invalidates the number entirely — drop it and prevent resurrection.
            lastSnapshot = nil
            state = .noToken
        case .unauthorized:
            // Expired token invalidates the number entirely — drop it and prevent resurrection.
            lastSnapshot = nil
            state = .unauthorized
        case .transport, .badStatus, .decoding:
            if let lastSnapshot {
                state = .stale(lastSnapshot, since: lastSnapshot.fetchedAt)
            } else {
                state = .unreachable
            }
        }
    }
}
