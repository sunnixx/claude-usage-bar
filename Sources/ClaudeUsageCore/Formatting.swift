import Foundation

/// How close a usage window is to its limit. Drives colour in the surfaces
/// that can render it; `Formatting.isCritical` still drives the menu bar
/// title, and `critical` here is defined to agree with it.
public enum Severity: Equatable, Sendable {
    case normal
    case warning
    case critical
}

public enum Formatting {
    public static let criticalThreshold = 90
    public static let warningThreshold = 75

    public static func severity(for percent: Int) -> Severity {
        if percent >= criticalThreshold { return .critical }
        if percent >= warningThreshold { return .warning }
        return .normal
    }

    public static func percentText(_ percent: Int?) -> String {
        guard let percent else { return "—" }
        return "\(percent)%"
    }

    public static func isCritical(_ percent: Int?) -> Bool {
        guard let percent else { return false }
        return percent >= criticalThreshold
    }

    public static func progressBar(percent: Int, width: Int = 10) -> String {
        let width = max(width, 0)
        let clamped = min(max(percent, 0), 100)
        let filled = min(width, Int((Double(clamped) / 100.0 * Double(width)).rounded()))
        return String(repeating: "▓", count: filled)
            + String(repeating: "░", count: width - filled)
    }

    public static func resetDescription(
        _ date: Date?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String? {
        guard let date else { return nil }

        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting now" }
        if seconds < 60 { return "resets in under a minute" }

        if seconds < 24 * 60 * 60 {
            let totalMinutes = Int(seconds / 60)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return hours == 0
                ? "resets in \(minutes)m"
                : "resets in \(hours)h \(minutes)m"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "EEE, MMM d"
        return "resets \(formatter.string(from: date))"
    }

    public static func clockTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
