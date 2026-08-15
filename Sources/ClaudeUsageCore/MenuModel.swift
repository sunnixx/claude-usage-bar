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

    public init(
        label: String,
        percent: Int? = nil,
        bar: String? = nil,
        reset: String? = nil,
        isIndented: Bool = false
    ) {
        self.label = label
        self.percent = percent
        self.bar = bar
        self.reset = reset
        self.isIndented = isIndented
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
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [MenuRow] {
        switch state {
        case .loading:
            return [MenuRow(label: "Loading…")]
        case .noToken:
            return [MenuRow(label: "Not signed in to Claude Code")]
        case .unauthorized:
            return [MenuRow(label: "Token expired — open Claude Code to refresh")]
        case .unreachable:
            return [MenuRow(label: "Can't reach Anthropic")]
        case .tokenStoreUnavailable:
            #if os(macOS)
            return [MenuRow(label: "Keychain access denied — allow in Keychain Access")]
            #else
            return [MenuRow(label: "Can't read Claude Code credentials")]
            #endif
        case .loaded(let snapshot):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(label: "Updated \(Formatting.clockTime(snapshot.fetchedAt, locale: locale, timeZone: timeZone))")]
        case .stale(let snapshot, let since):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(label: "Offline — updated \(Formatting.clockTime(since, locale: locale, timeZone: timeZone))")]
        }
    }

    private static func usageRows(
        _ snapshot: UsageSnapshot,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [MenuRow] {
        var rows: [MenuRow] = []

        if let session = snapshot.session {
            rows.append(row(label: "Session (5h)", window: session,
                            now: now, calendar: calendar, locale: locale))
        }
        if let week = snapshot.week {
            rows.append(row(label: "This week", window: week,
                            now: now, calendar: calendar, locale: locale))
        }
        for scope in snapshot.scopedWeekly {
            rows.append(row(
                label: scope.label,
                window: UsageWindow(percent: scope.percent, resetsAt: scope.resetsAt),
                now: now, calendar: calendar, locale: locale,
                indented: true
            ))
        }

        return rows
    }

    private static func row(
        label: String,
        window: UsageWindow,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        indented: Bool = false
    ) -> MenuRow {
        MenuRow(
            label: label,
            percent: window.percent,
            bar: Formatting.progressBar(percent: window.percent),
            reset: Formatting.resetDescription(
                window.resetsAt, now: now, calendar: calendar, locale: locale
            ),
            isIndented: indented
        )
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
