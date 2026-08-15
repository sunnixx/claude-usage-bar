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

    /// Codex window durations are plan-dependent — a free plan reports one
    /// 30-day window, paid plans report a 5-hour and a weekly one — so labels
    /// are derived from the duration rather than hardcoded.
    static func windowLabel(seconds: Int) -> String {
        if seconds == 604_800 { return "This week" }
        if seconds >= 86_400, seconds % 86_400 == 0 { return "\(seconds / 86_400) days" }
        return "\(max(1, Int((Double(seconds) / 3600).rounded(.up))))h"
    }
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
