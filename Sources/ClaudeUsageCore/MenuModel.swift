import Foundation

public struct StatusTitle: Equatable, Sendable {
    public let text: String
    public let isCritical: Bool
    public let isStale: Bool
}

public struct MenuRow: Equatable, Sendable {
    public let text: String
    public let isIndented: Bool

    public init(text: String, isIndented: Bool = false) {
        self.text = text
        self.isIndented = isIndented
    }
}

/// Turns poller state into the exact strings both AppKit surfaces display.
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
            return [MenuRow(text: "Loading…")]
        case .noToken:
            return [MenuRow(text: "Not signed in to Claude Code")]
        case .unauthorized:
            return [MenuRow(text: "Token expired — open Claude Code to refresh")]
        case .unreachable:
            return [MenuRow(text: "Can't reach Anthropic")]
        case .tokenStoreUnavailable:
            #if os(macOS)
            return [MenuRow(text: "Keychain access denied — allow in Keychain Access")]
            #else
            return [MenuRow(text: "Can't read Claude Code credentials")]
            #endif
        case .loaded(let snapshot):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(text: "Updated \(Formatting.clockTime(snapshot.fetchedAt, locale: locale, timeZone: timeZone))")]
        case .stale(let snapshot, let since):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(text: "Offline — updated \(Formatting.clockTime(since, locale: locale, timeZone: timeZone))")]
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
            rows.append(MenuRow(text: line(
                label: "Session (5h)", window: session, now: now, calendar: calendar, locale: locale
            )))
        }
        if let week = snapshot.week {
            rows.append(MenuRow(text: line(
                label: "This week", window: week, now: now, calendar: calendar, locale: locale
            )))
        }
        for scope in snapshot.scopedWeekly {
            rows.append(MenuRow(
                text: line(
                    label: scope.label,
                    window: UsageWindow(percent: scope.percent, resetsAt: scope.resetsAt),
                    now: now, calendar: calendar, locale: locale,
                    indented: true
                ),
                isIndented: true
            ))
        }

        return rows
    }

    private static func line(
        label: String,
        window: UsageWindow,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        indented: Bool = false
    ) -> String {
        let displayLabel = indented ? "└ \(label)" : label
        let paddedLabel = displayLabel.padding(
            toLength: max(labelWidth, displayLabel.count), withPad: " ", startingAt: 0
        )
        let percent = String(
            repeating: " ",
            count: max(0, percentWidth - Formatting.percentText(window.percent).count)
        ) + Formatting.percentText(window.percent)
        let bar = Formatting.progressBar(percent: window.percent)

        var line = "\(paddedLabel)\(percent)  \(bar)"
        if let reset = Formatting.resetDescription(
            window.resetsAt, now: now, calendar: calendar, locale: locale
        ) {
            line += "  \(reset)"
        }
        return line
    }
}
