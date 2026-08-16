import Foundation

/// One provider's worth of dropdown content, grouped rather than flattened.
///
/// The macOS card layout needs structure the flat `MenuRow` list cannot express:
/// which window is the headline, which are secondary, and what the provider's
/// own status is. Linux and Windows keep using the flat `MenuModel.rows`.
public struct ProviderSection: Equatable, Sendable {
    public let provider: Provider
    /// Codex reports one; Anthropic's endpoint does not.
    public let planName: String?
    /// The window that gates you soonest — the card's large number. Selected by
    /// role, never by position: showing a weekly figure where the session figure
    /// belongs would be a wrong number under a right label.
    public let hero: UsageWindow?
    /// Everything else, in the order the provider reported it.
    public let others: [UsageWindow]
    /// "06:31" when loaded, or "Rate limited · 06:31" when stale — the cause,
    /// not just a time. Nil when there is no data at all.
    public let status: String?
    /// Set instead of the windows when the provider has nothing to show:
    /// "Not signed in to Codex", "Can't reach OpenAI".
    public let message: String?

    public init(
        provider: Provider,
        planName: String?,
        hero: UsageWindow?,
        others: [UsageWindow],
        status: String?,
        message: String?
    ) {
        self.provider = provider
        self.planName = planName
        self.hero = hero
        self.others = others
        self.status = status
        self.message = message
    }
}

extension MenuModel {
    /// Groups each provider's state into a `ProviderSection` for the card layout.
    ///
    /// Sits beside `rows(for:)` rather than replacing it — the flat list is still
    /// what Linux and Windows render.
    public static func sections(
        for states: [(Provider, UsageState)],
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [ProviderSection] {
        states.map { provider, state in
            switch state {
            case .loaded(let snapshot), .stale(let snapshot, _, _):
                return ProviderSection(
                    provider: provider,
                    planName: snapshot.planName,
                    hero: snapshot.windows.first { $0.role == .primary },
                    others: snapshot.windows.filter { $0.role != .primary },
                    status: statusText(for: state, locale: locale, timeZone: timeZone),
                    message: nil
                )
            default:
                // No data: the card shows the provider's message in place of
                // its windows, so a Claude failure and a Codex failure are
                // never confused.
                let rows = MenuModel.rows(
                    for: state, provider: provider,
                    now: now, calendar: calendar, locale: locale, timeZone: timeZone
                )
                return ProviderSection(
                    provider: provider,
                    planName: nil,
                    hero: nil,
                    others: [],
                    status: nil,
                    message: rows.first?.label
                )
            }
        }
    }

    private static func statusText(
        for state: UsageState,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        switch state {
        case .loaded(let snapshot):
            return Formatting.clockTime(snapshot.fetchedAt, locale: locale, timeZone: timeZone)
        case .stale(_, let since, let reason):
            let time = Formatting.clockTime(since, locale: locale, timeZone: timeZone)
            return "\(reason.rowText) · \(time)"
        default:
            return nil
        }
    }
}
