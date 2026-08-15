import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct TrayContentTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = locale
        return calendar
    }

    private func snapshot() throws -> UsageSnapshot {
        UsageSnapshot(
            session: UsageWindow(
                percent: 37,
                resetsAt: try #require(ISO8601Flexible.date(from: "2026-08-04T09:00:00Z"))
            ),
            week: UsageWindow(
                percent: 26,
                resetsAt: try #require(ISO8601Flexible.date(from: "2026-08-08T07:00:00Z"))
            ),
            scopedWeekly: [ScopedWindow(label: "Fable", percent: 10, resetsAt: nil)],
            fetchedAt: try #require(ISO8601Flexible.date(from: "2026-08-04T07:48:00Z"))
        )
    }

    @Test func buildsContentFromStateAndLoginFlag() throws {
        let state = UsageState.loaded(try snapshot())
        let content = TrayContent(
            title: MenuModel.statusTitle(for: state),
            rows: MenuModel.rows(
                for: state, now: try #require(ISO8601Flexible.date(from: "2026-08-04T07:48:00Z")),
                calendar: calendar, locale: locale, timeZone: utc
            ),
            loginItemEnabled: true
        )

        #expect(content.title.percent == 37)
        #expect(content.loginItemEnabled)
        #expect(!content.rows.isEmpty)
    }
}
