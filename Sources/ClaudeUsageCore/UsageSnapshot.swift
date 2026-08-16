import Foundation

/// Decodes Anthropic's usage response. The decoding logic is unchanged — only
/// the type it produces is now the shared `ProviderSnapshot`.
public enum UsageSnapshot {
    public static func decode(from data: Data, fetchedAt: Date) throws -> ProviderSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return snapshot(from: payload, fetchedAt: fetchedAt)
    }
}

extension UsageSnapshot {
    /// Mirrors the API response. Nearly every field is plan-dependent and may
    /// be absent or null, so everything here is optional.
    struct Payload: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }

        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    let display_name: String?
                }
                let model: Model?
            }

            let kind: String?
            let percent: Double?
            let resets_at: String?
            let scope: Scope?
        }

        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
    }

    static func snapshot(from payload: Payload, fetchedAt: Date) -> ProviderSnapshot {
        let limits = payload.limits ?? []

        func window(kind: String, label: String, role: WindowRole, fallback: Payload.Window?) -> UsageWindow? {
            if let limit = limits.first(where: { $0.kind == kind }), let percent = limit.percent {
                return UsageWindow(
                    label: label,
                    percent: Int(percent.rounded()),
                    resetsAt: limit.resets_at.flatMap(ISO8601Flexible.date(from:)),
                    role: role
                )
            }
            guard let fallback, let utilization = fallback.utilization else { return nil }
            return UsageWindow(
                label: label,
                percent: Int(utilization.rounded()),
                resetsAt: fallback.resets_at.flatMap(ISO8601Flexible.date(from:)),
                role: role
            )
        }

        var windows: [UsageWindow] = []
        // Session first: `ProviderSnapshot.primary` selects by role, but the
        // dropdown ordering is still positional, so session still leads.
        if let session = window(kind: "session", label: "Session (5h)", role: .primary, fallback: payload.five_hour) {
            windows.append(session)
        }
        let weekly = window(kind: "weekly_all", label: "This week", role: .secondary, fallback: payload.seven_day)
        if let weekly { windows.append(weekly) }

        for limit in limits {
            guard limit.kind == "weekly_scoped",
                  let label = limit.scope?.model?.display_name,
                  let percent = limit.percent
            else { continue }
            let resetsAt = limit.resets_at.flatMap(ISO8601Flexible.date(from:))
            // A scope that resets with the weekly window doesn't repeat the date.
            let repeatsWeekly = resetsAt != nil && resetsAt == weekly?.resetsAt
            windows.append(UsageWindow(
                label: label,
                percent: Int(percent.rounded()),
                resetsAt: repeatsWeekly ? nil : resetsAt,
                role: .scoped
            ))
        }

        return ProviderSnapshot(
            provider: .anthropic, planName: nil, windows: windows, fetchedAt: fetchedAt
        )
    }
}
