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
///
/// `provider` is `nil` only for the "no provider has a value" placeholder
/// `statusSegments` returns when nobody is signed in to anything: there is no
/// provider to name, and attributing that placeholder to either provider
/// would falsely imply that specific one is what's unavailable.
public struct StatusSegment: Equatable, Sendable {
    public let provider: Provider?
    public let text: String
    public let percent: Int?
    public let isCritical: Bool
    public let isStale: Bool

    public init(provider: Provider?, text: String, percent: Int?, isCritical: Bool, isStale: Bool) {
        self.provider = provider
        self.text = text
        self.percent = percent
        self.isCritical = isCritical
        self.isStale = isStale
    }
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
        provider: Provider,
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
            // Naming the *service* we couldn't reach, not the *CLI* — `cli`
            // above is "Claude Code" / "Codex", but the thing that failed
            // here is the API call (api.anthropic.com / the ChatGPT backend),
            // not the CLI. Getting this wrong is exactly the defect class
            // this project has hit before: the right message under the
            // wrong provider's name.
            let service = provider == .anthropic ? "Anthropic" : "OpenAI"
            return [MenuRow(label: "Can't reach \(service)")]
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
        // Markless and providerless: attributing this to either provider
        // would falsely imply that specific one is what's unavailable, when
        // neither has a value. See `AppKitTray.renderTitle`, which skips
        // drawing a mark for a `nil` provider.
        return [StatusSegment(
            provider: nil,
            text: Formatting.percentText(nil),
            percent: nil,
            isCritical: false,
            isStale: false
        )]
    }

    /// Composes each segment's provider name and reading into a single
    /// string, e.g. "Claude 37% · Codex 8%" — shared by the Linux menu-bar
    /// label (`AppIndicatorTray`) and the Windows tray tooltip (`Win32Tray`)
    /// so both name providers identically rather than each writing its own
    /// composition. A segment with no provider (the neither-signed-in
    /// placeholder from `statusSegments`) contributes just its text, since
    /// there is no provider name to attach.
    public static func composedLabel(for segments: [StatusSegment]) -> String {
        segments.map { segment in
            guard let provider = segment.provider else { return segment.text }
            return "\(provider.displayName) \(segment.text)"
        }.joined(separator: " · ")
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
