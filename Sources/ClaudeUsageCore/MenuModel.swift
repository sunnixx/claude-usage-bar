import Foundation

public struct StatusTitle: Equatable, Sendable {
    /// The formatted string macOS and Linux display beside the icon, e.g. "◔ 37%".
    public let text: String
    /// The raw number. Windows draws this into the icon bitmap itself, because
    /// the Win32 tray has no text field — so it must not have to parse `text`.
    public let percent: Int?
    public let isCritical: Bool
    public let isStale: Bool
}

public struct MenuRow: Equatable, Sendable {
    public let label: String
    public let percent: Int?
    public let bar: String?
    public let reset: String?
    public let isIndented: Bool
    /// How close this window is to its limit. `.normal` for rows that carry no
    /// percentage (message rows), which never render a meter.
    public let severity: Severity
    /// A per-provider section heading, e.g. "CODEX · free". Renders as a plain
    /// label with no percent, bar or reset.
    public let isSectionHeader: Bool

    public init(
        label: String,
        percent: Int? = nil,
        bar: String? = nil,
        reset: String? = nil,
        isIndented: Bool = false,
        isSectionHeader: Bool = false
    ) {
        self.label = label
        self.percent = percent
        self.bar = bar
        self.reset = reset
        self.isIndented = isIndented
        self.severity = percent.map(Formatting.severity(for:)) ?? .normal
        self.isSectionHeader = isSectionHeader
    }
}

/// One provider's contribution to the menu bar item.
public struct StatusSegment: Equatable, Sendable {
    public let provider: Provider
    public let text: String
    public let percent: Int?
    public let isCritical: Bool
    public let isStale: Bool
}

/// Turns poller state into the exact strings the macOS and Linux tray
/// surfaces display (Windows composes its own line — see `Win32Tray.line`
/// — because Win32 menus use a proportional font, not a monospaced one).
public enum MenuModel {
    private static let labelWidth = 14
    private static let percentWidth = 4

    public static func statusTitle(for state: UsageState) -> StatusTitle {
        let percent = state.displayPercent
        let isStale: Bool
        if case .stale = state {
            isStale = true
        } else {
            isStale = false
        }
        return StatusTitle(
            text: Formatting.percentText(percent),
            percent: percent,
            isCritical: Formatting.isCritical(percent),
            isStale: isStale
        )
    }

    public static func rows(
        for state: UsageState,
        provider: Provider = .anthropic,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [MenuRow] {
        let cli = provider == .anthropic ? "Claude Code" : "Codex"
        switch state {
        case .loading:
            return [MenuRow(label: "Loading…")]
        case .noToken:
            return [MenuRow(label: "Not signed in to \(cli)")]
        case .unauthorized:
            return [MenuRow(label: "Token expired — open \(cli) to refresh")]
        case .unreachable:
            return [MenuRow(label: "Can't reach Anthropic")]
        case .tokenStoreUnavailable:
            #if os(macOS)
            return [MenuRow(label: "Keychain access denied — allow in Keychain Access")]
            #else
            return [MenuRow(label: "Can't read \(cli) credentials")]
            #endif
        case .loaded(let snapshot):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(label: "Updated \(Formatting.clockTime(snapshot.fetchedAt, locale: locale, timeZone: timeZone))")]
        case .stale(let snapshot, let since, let reason):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(label: "\(reason.rowText) — updated \(Formatting.clockTime(since, locale: locale, timeZone: timeZone))")]
        }
    }

    public static func statusSegments(for states: [(Provider, UsageState)]) -> [StatusSegment] {
        let segments = states.compactMap { provider, state -> StatusSegment? in
            // A provider with no value contributes nothing rather than a dash —
            // two dashes in the menu bar would be noise.
            guard let percent = state.displayPercent else { return nil }
            let isStale: Bool
            if case .stale = state { isStale = true } else { isStale = false }
            return StatusSegment(
                provider: provider,
                text: Formatting.percentText(percent),
                percent: percent,
                isCritical: Formatting.isCritical(percent),
                isStale: isStale
            )
        }

        guard segments.isEmpty else { return segments }
        return [StatusSegment(
            provider: states.first?.0 ?? .anthropic,
            text: Formatting.percentText(nil),
            percent: nil,
            isCritical: false,
            isStale: false
        )]
    }

    public static func rows(
        for states: [(Provider, UsageState)],
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [MenuRow] {
        let showHeaders = states.count > 1
        return states.flatMap { provider, state -> [MenuRow] in
            var section: [MenuRow] = []
            if showHeaders {
                var heading = provider.displayName.uppercased()
                if let plan = planName(of: state) { heading += " · \(plan)" }
                section.append(MenuRow(label: heading, isSectionHeader: true))
            }
            section.append(contentsOf: rows(
                for: state, provider: provider,
                now: now, calendar: calendar, locale: locale, timeZone: timeZone
            ))
            return section
        }
    }

    private static func planName(of state: UsageState) -> String? {
        switch state {
        case .loaded(let snapshot): return snapshot.planName
        case .stale(let snapshot, _, _): return snapshot.planName
        default: return nil
        }
    }

    private static func usageRows(
        _ snapshot: ProviderSnapshot,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [MenuRow] {
        snapshot.windows.map { window in
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
    }

    /// Composes the padded, column-aligned line the macOS menu renders in a
    /// monospaced font. Lives here rather than in the AppKit layer so it stays
    /// testable — the earlier column-misalignment bug survived review precisely
    /// because the padding was correct in isolation while the rendered result
    /// was not.
    ///
    /// The indent prefix is composed *inside* the label field so that it is
    /// absorbed by the padding, rather than prepended afterwards and pushing
    /// the row out of alignment.
    public static func monospaceLine(_ row: MenuRow) -> String {
        let displayLabel = row.isIndented ? "└ \(row.label)" : row.label
        let paddedLabel = displayLabel.padding(
            toLength: max(labelWidth, displayLabel.count), withPad: " ", startingAt: 0
        )

        guard let percent = row.percent else { return paddedLabel.trimmingCharacters(in: .whitespaces) }

        let percentText = Formatting.percentText(percent)
        let paddedPercent = String(
            repeating: " ", count: max(0, percentWidth - percentText.count)
        ) + percentText

        var line = "\(paddedLabel)\(paddedPercent)"
        if let bar = row.bar { line += "  \(bar)" }
        if let reset = row.reset { line += "  \(reset)" }
        return line
    }
}
