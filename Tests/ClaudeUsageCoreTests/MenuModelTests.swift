import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct MenuModelTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = locale
        return calendar
    }

    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601Flexible.date(from: iso))
    }

    private func loadedSnapshot() throws -> UsageSnapshot {
        UsageSnapshot(
            session: UsageWindow(percent: 37, resetsAt: try date("2026-08-04T09:00:00Z")),
            week: UsageWindow(percent: 26, resetsAt: try date("2026-08-08T07:00:00Z")),
            scopedWeekly: [ScopedWindow(label: "Fable", percent: 10, resetsAt: nil)],
            fetchedAt: try date("2026-08-04T07:48:00Z")
        )
    }

    private func rows(_ state: UsageState, now: Date) -> [String] {
        MenuModel.rows(for: state, now: now, calendar: calendar, locale: locale, timeZone: utc)
            .map(\.text)
    }

    // MARK: statusTitle

    @Test func showsThePercentageWhenLoaded() throws {
        let title = MenuModel.statusTitle(for: .loaded(try loadedSnapshot()))

        #expect(title.text == "37%")
        #expect(title.isCritical == false)
    }

    @Test func marksHighUsageAsCritical() throws {
        let snapshot = UsageSnapshot(
            session: UsageWindow(percent: 93, resetsAt: nil),
            week: nil,
            scopedWeekly: [],
            fetchedAt: try date("2026-08-04T07:48:00Z")
        )

        #expect(MenuModel.statusTitle(for: .loaded(snapshot)).isCritical == true)
    }

    @Test(arguments: [UsageState.loading, .noToken, .unauthorized, .unreachable, .tokenStoreUnavailable])
    func showsADashWhenThereIsNoValue(state: UsageState) {
        let title = MenuModel.statusTitle(for: state)

        #expect(title.text == "—")
        #expect(title.isCritical == false)
    }

    @Test func keepsShowingTheLastValueWhenStale() throws {
        let snapshot = try loadedSnapshot()
        let title = MenuModel.statusTitle(for: .stale(snapshot, since: snapshot.fetchedAt))

        #expect(title.text == "37%")
    }

    @Test(arguments: [UsageState.loading, .noToken, .unauthorized, .unreachable, .tokenStoreUnavailable])
    func isStaleIsFalseForNonStaleStates(state: UsageState) {
        #expect(MenuModel.statusTitle(for: state).isStale == false)
    }

    @Test func isStaleIsFalseWhenLoaded() throws {
        #expect(MenuModel.statusTitle(for: .loaded(try loadedSnapshot())).isStale == false)
    }

    @Test func isStaleIsTrueWhenStale() throws {
        let snapshot = try loadedSnapshot()
        #expect(MenuModel.statusTitle(for: .stale(snapshot, since: snapshot.fetchedAt)).isStale == true)
    }

    // MARK: rows

    @Test func listsBothWindowsAndEachScope() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let text = rows(.loaded(try loadedSnapshot()), now: now)

        #expect(text.count == 4)
        #expect(text[0] == "Session (5h)   37%  ▓▓▓▓░░░░░░  resets in 1h 12m")
        #expect(text[1] == "This week      26%  ▓▓▓░░░░░░░  resets Sat, Aug 8")
        #expect(text[2] == "└ Fable        10%  ▓░░░░░░░░░")
        #expect(text[3] == "Updated 07:48")
    }

    @Test func indentsScopeRowsOnly() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let menuRows = MenuModel.rows(
            for: .loaded(try loadedSnapshot()),
            now: now, calendar: calendar, locale: locale, timeZone: utc
        )

        #expect(menuRows.map(\.isIndented) == [false, false, true, false])
    }

    @Test func omitsScopeRowsWhenThePlanHasNone() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let snapshot = UsageSnapshot(
            session: UsageWindow(percent: 4, resetsAt: nil),
            week: UsageWindow(percent: 0, resetsAt: nil),
            scopedWeekly: [],
            fetchedAt: now
        )

        let text = rows(.loaded(snapshot), now: now)

        #expect(text.count == 3)
        #expect(text[0] == "Session (5h)    4%  ░░░░░░░░░░")
    }

    @Test func marksStaleDataWithTheLastSuccessTime() throws {
        let snapshot = try loadedSnapshot()
        let now = try date("2026-08-04T08:10:00Z")

        let text = rows(.stale(snapshot, since: snapshot.fetchedAt), now: now)

        #expect(text.last == "Offline — updated 07:48")
    }

    @Test func explainsEachFailureState() throws {
        let now = try date("2026-08-04T07:48:00Z")

        #expect(rows(.loading, now: now) == ["Loading…"])
        #expect(rows(.noToken, now: now) == ["Not signed in to Claude Code"])
        #expect(rows(.unauthorized, now: now) == ["Token expired — open Claude Code to refresh"])
        #expect(rows(.unreachable, now: now) == ["Can't reach Anthropic"])
        #expect(rows(.tokenStoreUnavailable, now: now) == ["Keychain access denied — allow in Keychain Access"])
    }
}
