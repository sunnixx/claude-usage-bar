import Foundation

public struct UsageWindow: Equatable, Sendable {
    public let percent: Int
    public let resetsAt: Date?

    public init(percent: Int, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct ScopedWindow: Equatable, Sendable {
    public let label: String
    public let percent: Int
    public let resetsAt: Date?

    public init(label: String, percent: Int, resetsAt: Date?) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let session: UsageWindow?
    public let week: UsageWindow?
    public let scopedWeekly: [ScopedWindow]
    public let fetchedAt: Date

    public init(
        session: UsageWindow?,
        week: UsageWindow?,
        scopedWeekly: [ScopedWindow],
        fetchedAt: Date
    ) {
        self.session = session
        self.week = week
        self.scopedWeekly = scopedWeekly
        self.fetchedAt = fetchedAt
    }

    public static func decode(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return UsageSnapshot(payload: payload, fetchedAt: fetchedAt)
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

    init(payload: Payload, fetchedAt: Date) {
        let limits = payload.limits ?? []

        func window(kind: String, fallback: Payload.Window?) -> UsageWindow? {
            if let limit = limits.first(where: { $0.kind == kind }), let percent = limit.percent {
                return UsageWindow(
                    percent: Int(percent.rounded()),
                    resetsAt: limit.resets_at.flatMap(ISO8601Flexible.date(from:))
                )
            }
            guard let fallback, let utilization = fallback.utilization else { return nil }
            return UsageWindow(
                percent: Int(utilization.rounded()),
                resetsAt: fallback.resets_at.flatMap(ISO8601Flexible.date(from:))
            )
        }

        self.init(
            session: window(kind: "session", fallback: payload.five_hour),
            week: window(kind: "weekly_all", fallback: payload.seven_day),
            scopedWeekly: limits.compactMap { limit in
                guard limit.kind == "weekly_scoped",
                      let label = limit.scope?.model?.display_name,
                      let percent = limit.percent
                else { return nil }
                return ScopedWindow(
                    label: label,
                    percent: Int(percent.rounded()),
                    resetsAt: limit.resets_at.flatMap(ISO8601Flexible.date(from:))
                )
            },
            fetchedAt: fetchedAt
        )
    }
}
