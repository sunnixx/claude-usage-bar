import Foundation

/// Parses the timestamps returned by the usage API.
///
/// Those timestamps carry six fractional-second digits
/// ("2026-08-04T09:00:00.782828+00:00"). `ISO8601DateFormatter` expects
/// exactly three and returns nil otherwise, so the fractional component is
/// removed before parsing. Sub-second precision does not matter for a reset
/// time shown to the minute.
public enum ISO8601Flexible {
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func date(from string: String) -> Date? {
        formatter.date(from: stripFractionalSeconds(string))
    }

    public static func stripFractionalSeconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber {
            end = string.index(after: end)
        }
        return String(string[string.startIndex..<dot]) + String(string[end...])
    }
}
