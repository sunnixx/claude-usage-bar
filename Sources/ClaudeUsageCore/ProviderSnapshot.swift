import Foundation

/// What a window is, so `primary` does not depend on array position.
public enum WindowRole: Equatable, Sendable {
    /// The window that gates you soonest — Anthropic's five-hour session,
    /// Codex's primary_window. This is what the menu bar segment shows.
    case primary
    /// A longer window shown in the dropdown only.
    case secondary
    /// A per-model or per-feature limit; renders indented.
    case scoped
}

/// One rate-limit window. Both providers reduce to a list of these: Anthropic's
/// five-hour, weekly and per-model windows, and Codex's primary, secondary and
/// additional ones.
public struct UsageWindow: Equatable, Sendable {
    public let label: String
    public let percent: Int
    public let resetsAt: Date?
    public let role: WindowRole

    public init(label: String, percent: Int, resetsAt: Date?, role: WindowRole = .secondary) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.role = role
    }

    /// Renders indented — Anthropic's per-model rows, Codex's additional limits.
    public var isScoped: Bool { role == .scoped }
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

    /// The window the menu bar segment shows. Selected by role, never by
    /// position: a provider that reports a weekly window but no session window
    /// must show no number rather than silently presenting the weekly figure
    /// as if it were the session one.
    public var primary: UsageWindow? { windows.first { $0.role == .primary } }
}
