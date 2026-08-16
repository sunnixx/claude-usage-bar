import Foundation

/// Decodes ChatGPT Codex's usage response.
///
/// The response also carries `email`, `user_id` and `account_id`. Those fields
/// are deliberately absent from `Payload`: the app has no use for them, and not
/// decoding them is the simplest way to guarantee they are never stored,
/// logged, or displayed.
public enum CodexSnapshot {
    public static func decode(from data: Data, fetchedAt: Date) throws -> ProviderSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        var windows: [UsageWindow] = []
        // Primary first: `ProviderSnapshot.primary` is selected by role, but
        // the dropdown ordering is still positional, so primary leads.
        if let window = payload.rate_limit?.primary_window.flatMap({ usageWindow($0, role: .primary) }) {
            windows.append(window)
        }
        if let window = payload.rate_limit?.secondary_window.flatMap({ usageWindow($0, role: .secondary) }) {
            windows.append(window)
        }
        for additional in payload.additional_rate_limits ?? [] {
            guard let window = usageWindow(additional, role: .scoped) else { continue }
            windows.append(window)
        }

        guard !windows.isEmpty else {
            // A usage response with no windows is not a usage response. Every
            // field above is Optional so a schema change (renamed keys, a
            // window with no used_percent) decodes "successfully" into
            // nothing rather than throwing. The endpoint is undocumented, so
            // treat that shape drift as a decoding failure — the refresh
            // policy then retains the last good value as stale instead of
            // blanking the readout.
            throw CodexDecodingError.noWindows
        }

        return ProviderSnapshot(
            provider: .codex,
            planName: payload.plan_type,
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    private static func usageWindow(_ window: Payload.Window, role: WindowRole) -> UsageWindow? {
        guard let percent = window.used_percent else { return nil }
        return UsageWindow(
            label: windowLabel(seconds: window.limit_window_seconds ?? 0),
            percent: Int(percent.rounded()),
            resetsAt: window.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            role: role
        )
    }

    /// Codex window durations are plan-dependent, so labels are derived from
    /// the duration rather than hardcoded. Only the free plan's shape — a
    /// single 30-day window — has been observed live; the paid-plan shape (a
    /// 5-hour primary and a weekly secondary) is inferred from the Codex
    /// source and encoded in the `codex-full` fixture, not confirmed live.
    static func windowLabel(seconds: Int) -> String {
        if seconds == 604_800 { return "This week" }
        if seconds >= 86_400, seconds % 86_400 == 0 { return "\(seconds / 86_400) days" }
        return "\(max(1, Int((Double(seconds) / 3600).rounded(.up))))h"
    }
}

/// Thrown when a syntactically valid Codex response decodes to no usable
/// windows — the "shape changed" case that all-optional fields would
/// otherwise let through as a silently empty, but "successful", snapshot.
enum CodexDecodingError: Error, Equatable {
    case noWindows
}

extension CodexSnapshot {
    struct Payload: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int?
            let reset_at: Int?
        }

        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }

        let plan_type: String?
        let rate_limit: RateLimit?
        let additional_rate_limits: [Window]?
    }
}
