import Foundation

/// One rate-limit window. Both providers reduce to a list of these: Anthropic's
/// five-hour, weekly and per-model windows, and Codex's primary, secondary and
/// additional ones.
public struct UsageWindow: Equatable, Sendable {
    public let label: String
    public let percent: Int
    public let resetsAt: Date?
    /// Renders indented — Anthropic's per-model rows, Codex's additional limits.
    public let isScoped: Bool

    public init(label: String, percent: Int, resetsAt: Date?, isScoped: Bool = false) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.isScoped = isScoped
    }
}

public struct ProviderSnapshot: Equatable, Sendable {
    public let provider: Provider
    /// Codex reports a plan name; Anthropic's endpoint does not.
    public let planName: String?
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public init(
        provider: Provider,
        planName: String?,
        windows: [UsageWindow],
        fetchedAt: Date
    ) {
        self.provider = provider
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    /// The window the menu bar segment shows — the one that gates you soonest.
    /// Producers must emit it first: Anthropic's session, Codex's primary.
    public var primary: UsageWindow? { windows.first }
}
