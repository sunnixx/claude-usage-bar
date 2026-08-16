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
    ///
    /// A `MenuRow` rather than a `UsageWindow` so the card reuses the same
    /// tested reset formatting every other surface uses, instead of re-deriving
    /// it from a date inside the view.
    public let hero: MenuRow?
    /// Everything else, in the order the provider reported it.
    public let others: [MenuRow]
    /// "06:31" when loaded, or "Rate limited · 06:31" when stale — the cause,
    /// not just a time. Nil when there is no data at all.
    public let status: String?
    /// Set instead of the windows when the provider has nothing to show:
    /// "Not signed in to Codex", "Can't reach OpenAI".
    public let message: String?

    public init(
        provider: Provider,
        planName: String?,
        hero: MenuRow?,
        others: [MenuRow],
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
                func row(_ window: UsageWindow) -> MenuRow {
                    MenuRow(
                        label: window.label,
                        percent: window.percent,
                        bar: Formatting.progressBar(percent: window.percent),
                        reset: Formatting.resetDescription(
                            window.resetsAt, now: now, calendar: calendar, locale: locale
                        ),
                        isIndented: window.isScoped
                    )
                }
                return ProviderSection(
                    provider: provider,
                    planName: snapshot.planName,
                    hero: snapshot.windows.first { $0.role == .primary }.map(row),
                    others: snapshot.windows.filter { $0.role != .primary }.map(row),
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
            let time = Formatting.clockTime(snapshot.fetchedAt, locale: locale, timeZone: timeZone)
            return "Last updated \(time)"
        case .stale(_, let since, let reason):
            // The reason leads, because it is why the number is old — but the
            // time still needs saying what it is the time of.
            let time = Formatting.clockTime(since, locale: locale, timeZone: timeZone)
            return "\(reason.rowText) · last updated \(time)"
        default:
            return nil
        }
    }
}
