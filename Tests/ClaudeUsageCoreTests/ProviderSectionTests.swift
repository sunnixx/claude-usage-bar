import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct ProviderSectionTests {
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

    private var now: Date { get throws { try date("2026-08-04T07:48:00Z") } }

    private func snapshot(
        _ provider: Provider,
        plan: String? = nil,
        windows: [UsageWindow]
    ) throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider, planName: plan, windows: windows,
            fetchedAt: try date("2026-08-04T06:31:00Z")
        )
    }

    private func sections(_ states: [(Provider, UsageState)]) throws -> [ProviderSection] {
        MenuModel.sections(
            for: states, now: try now,
            calendar: calendar, locale: locale, timeZone: utc
        )
    }

    // MARK: - Grouping

    @Test func groupsEachProviderIntoItsOwnSection() throws {
        let result = try sections([
            (.anthropic, .loaded(try snapshot(.anthropic, windows: [
                UsageWindow(label: "Session (5h)", percent: 5, resetsAt: nil, role: .primary),
            ]))),
            (.codex, .loaded(try snapshot(.codex, plan: "free", windows: [
                UsageWindow(label: "30 days", percent: 0, resetsAt: nil, role: .primary),
            ]))),
        ])

        #expect(result.count == 2)
        #expect(result[0].provider == .anthropic)
        #expect(result[1].provider == .codex)
    }

    @Test func theHeroIsTheRoleTaggedPrimaryNotTheFirstWindow() throws {
        // The card's big number must be the window that gates you soonest.
        // Selecting it by position would show a weekly figure as a session one.
        let result = try sections([
            (.anthropic, .loaded(try snapshot(.anthropic, windows: [
                UsageWindow(label: "This week", percent: 13, resetsAt: nil, role: .secondary),
                UsageWindow(label: "Session (5h)", percent: 5, resetsAt: nil, role: .primary),
            ]))),
        ])

        let hero = try #require(result[0].hero)
        #expect(hero.label == "Session (5h)")
        #expect(hero.percent == 5)
    }

    @Test func everythingThatIsNotTheHeroBecomesASecondaryRow() throws {
        let result = try sections([
            (.anthropic, .loaded(try snapshot(.anthropic, windows: [
                UsageWindow(label: "Session (5h)", percent: 5, resetsAt: nil, role: .primary),
                UsageWindow(label: "This week", percent: 13, resetsAt: nil, role: .secondary),
                UsageWindow(label: "Fable", percent: 7, resetsAt: nil, role: .scoped),
            ]))),
        ])

        #expect(result[0].others.map(\.label) == ["This week", "Fable"])
        #expect(result[0].others.map(\.isIndented) == [false, true])
    }

    @Test func carriesThePlanNameWhenTheProviderReportsOne() throws {
        let result = try sections([
            (.codex, .loaded(try snapshot(.codex, plan: "free", windows: [
                UsageWindow(label: "30 days", percent: 0, resetsAt: nil, role: .primary),
            ]))),
        ])

        #expect(result[0].planName == "free")
    }

    @Test func hasNoPlanNameWhenTheProviderReportsNone() throws {
        let result = try sections([
            (.anthropic, .loaded(try snapshot(.anthropic, windows: [
                UsageWindow(label: "Session (5h)", percent: 5, resetsAt: nil, role: .primary),
            ]))),
        ])

        #expect(result[0].planName == nil)
    }

    // MARK: - Status line

    @Test func showsTheUpdateTimeWhenLoaded() throws {
        let result = try sections([
            (.anthropic, .loaded(try snapshot(.anthropic, windows: [
                UsageWindow(label: "Session (5h)", percent: 5, resetsAt: nil, role: .primary),
            ]))),
        ])

        // A bare time says nothing about what it is the time of.
        #expect(result[0].status == "Last updated 06:31")
    }

    @Test func namesTheCauseWhenStaleRatherThanJustATime() throws {
        let result = try sections([
            (.anthropic, .stale(
                try snapshot(.anthropic, windows: [
                    UsageWindow(label: "Session (5h)", percent: 5, resetsAt: nil, role: .primary),
                ]),
                since: try date("2026-08-04T06:31:00Z"),
                reason: .rateLimited
            )),
        ])

        let status = try #require(result[0].status)
        #expect(status == "Rate limited · last updated 06:31")
    }

    // MARK: - Error states

    @Test func aProviderWithNoDataHasNoHeroButKeepsItsMessage() throws {
        let result = try sections([(.codex, .noToken)])

        #expect(result.count == 1)
        #expect(result[0].hero == nil)
        #expect(result[0].others.isEmpty)
        #expect(result[0].message == "Not signed in to Codex")
    }

    @Test func namesTheRightServiceForAnUnreachableProvider() throws {
        // The card must not tell a Codex user we can't reach Anthropic.
        let result = try sections([(.codex, .unreachable)])
        #expect(result[0].message == "Can't reach OpenAI")
    }

    @Test func aLoadedProviderHasNoMessage() throws {
        let result = try sections([
            (.anthropic, .loaded(try snapshot(.anthropic, windows: [
                UsageWindow(label: "Session (5h)", percent: 5, resetsAt: nil, role: .primary),
            ]))),
        ])

        #expect(result[0].message == nil)
    }
}
