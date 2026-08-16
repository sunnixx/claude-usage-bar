import Foundation
import Testing
@testable import HeadroomCore

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

    private func loadedSnapshot() throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [
                UsageWindow(label: "Session (5h)", percent: 37, resetsAt: try date("2026-08-04T09:00:00Z"), role: .primary),
                UsageWindow(label: "This week", percent: 26, resetsAt: try date("2026-08-08T07:00:00Z")),
                UsageWindow(label: "Fable", percent: 10, resetsAt: nil, role: .scoped),
            ],
            fetchedAt: try date("2026-08-04T07:48:00Z")
        )
    }

    private func rows(_ state: UsageState, now: Date, provider: Provider = .anthropic) -> [String] {
        MenuModel.rows(for: state, provider: provider, now: now, calendar: calendar, locale: locale, timeZone: utc)
            .map(MenuModel.monospaceLine)
    }

    // MARK: statusTitle

    @Test func showsThePercentageWhenLoaded() throws {
        let title = MenuModel.statusTitle(for: .loaded(try loadedSnapshot()))

        #expect(title.text == "37%")
        #expect(title.isCritical == false)
    }

    @Test func marksHighUsageAsCritical() throws {
        let snapshot = ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [UsageWindow(label: "Session (5h)", percent: 93, resetsAt: nil, role: .primary)],
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
        let title = MenuModel.statusTitle(for: .stale(snapshot, since: snapshot.fetchedAt, reason: .offline))

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
        #expect(MenuModel.statusTitle(for: .stale(snapshot, since: snapshot.fetchedAt, reason: .offline)).isStale == true)
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
            for: .loaded(try loadedSnapshot()), provider: .anthropic,
            now: now, calendar: calendar, locale: locale, timeZone: utc
        )

        #expect(menuRows.map(\.isIndented) == [false, false, true, false])
    }

    @Test func omitsScopeRowsWhenThePlanHasNone() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let snapshot = ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [
                UsageWindow(label: "Session (5h)", percent: 4, resetsAt: nil, role: .primary),
                UsageWindow(label: "This week", percent: 0, resetsAt: nil),
            ],
            fetchedAt: now
        )

        let text = rows(.loaded(snapshot), now: now)

        #expect(text.count == 3)
        #expect(text[0] == "Session (5h)    4%  ░░░░░░░░░░")
    }

    @Test func marksStaleDataWithTheLastSuccessTime() throws {
        let snapshot = try loadedSnapshot()
        let now = try date("2026-08-04T08:10:00Z")

        let text = rows(.stale(snapshot, since: snapshot.fetchedAt, reason: .offline), now: now)

        #expect(text.last == "Offline — updated 07:48")
    }

    @Test func explainsEachFailureState() throws {
        let now = try date("2026-08-04T07:48:00Z")

        #expect(rows(.loading, now: now) == ["Loading…"])
        #expect(rows(.noToken, now: now) == ["Not signed in to Claude Code"])
        #expect(rows(.unauthorized, now: now) == ["Token expired — open Claude Code to refresh"])
        #expect(rows(.unreachable, now: now) == ["Can't reach Anthropic"])
        #if os(macOS)
        #expect(rows(.tokenStoreUnavailable, now: now) == ["Keychain access denied — allow in Keychain Access"])
        #else
        #expect(rows(.tokenStoreUnavailable, now: now) == ["Can't read Claude Code credentials"])
        #endif
    }

    /// A Codex transport failure must never be labelled "Can't reach
    /// Anthropic" — for a user signed into Codex but not Claude Code, that
    /// wording names a company they aren't even signed into. Regression
    /// coverage for the defect this project has hit repeatedly: the right
    /// message rendered under the wrong provider's name.
    @Test func namesTheRightServiceForACodexFailure() throws {
        let now = try date("2026-08-04T07:48:00Z")

        #expect(rows(.unreachable, now: now, provider: .codex) == ["Can't reach OpenAI"])
        #expect(rows(.noToken, now: now, provider: .codex) == ["Not signed in to Codex"])
        #expect(rows(.unauthorized, now: now, provider: .codex) == ["Token expired — open Codex to refresh"])
    }

    // MARK: structured rows

    @Test func buildsStructuredRowsForASnapshot() throws {
        let rows = MenuModel.rows(
            for: .loaded(try loadedSnapshot()), provider: .anthropic, now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )

        let session = try #require(rows.first)
        #expect(session.label == "Session (5h)")
        #expect(session.percent == 37)
        #expect(session.bar == "\u{2593}\u{2593}\u{2593}\u{2593}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}")
        #expect(session.isIndented == false)
    }

    @Test func marksScopedRowsAsIndented() throws {
        let rows = MenuModel.rows(
            for: .loaded(try loadedSnapshot()), provider: .anthropic, now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )
        let scoped = try #require(rows.first { $0.isIndented })
        #expect(scoped.label == "Fable")
        #expect(scoped.percent == 10)
    }

    @Test func messageRowsCarryOnlyALabel() throws {
        let rows = MenuModel.rows(
            for: .noToken, provider: .anthropic, now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )
        let row = try #require(rows.first)
        #expect(row.label == "Not signed in to Claude Code")
        #expect(row.percent == nil)
        #expect(row.bar == nil)
        #expect(row.reset == nil)
    }

    @Test func composesAMonospaceLineWithAlignedColumns() {
        let plain = MenuRow(label: "This week", percent: 26,
                            bar: "\u{2593}\u{2593}\u{2593}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}", reset: "resets Sat, Aug 8")
        let indented = MenuRow(label: "Fable", percent: 10,
                               bar: "\u{2593}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}", reset: nil, isIndented: true)

        let a = MenuModel.monospaceLine(plain)
        let b = MenuModel.monospaceLine(indented)

        // The percent sign and the bar must sit at the same index on both rows --
        // the indent is absorbed by the label field, not prepended afterwards.
        #expect(a.distance(from: a.startIndex, to: a.firstIndex(of: "%")!) == 17)
        #expect(b.distance(from: b.startIndex, to: b.firstIndex(of: "%")!) == 17)
        #expect(a.distance(from: a.startIndex, to: a.firstIndex(of: "\u{2593}")!) == 20)
        #expect(b.distance(from: b.startIndex, to: b.firstIndex(of: "\u{2593}")!) == 20)
    }

    @Test func statusTitleCarriesTheRawPercent() throws {
        let title = MenuModel.statusTitle(for: .loaded(try loadedSnapshot()))
        #expect(title.percent == 37)
        // The gauge glyph is the status item's template image, not part of this
        // string -- do not add it here.
        #expect(title.text == "37%")
    }

    @Test func statusTitlePercentIsNilWithoutAValue() {
        #expect(MenuModel.statusTitle(for: .noToken).percent == nil)
    }
}

// MARK: - Severity
//
// The scope-reset de-duplication tests that used to live here moved to
// UsageSnapshotTests: the behaviour itself moved into the Anthropic decoder,
// since it's a property of the decoded data, not of MenuModel's presentation.

extension MenuModelTests {
    private func snapshot(
        sessionPercent: Int,
        weekPercent: Int,
        scopeResetsAt: Date?
    ) throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [
                UsageWindow(label: "Session (5h)", percent: sessionPercent, resetsAt: try date("2026-08-04T09:00:00Z"), role: .primary),
                UsageWindow(label: "This week", percent: weekPercent, resetsAt: try date("2026-08-08T07:00:00Z")),
                UsageWindow(label: "Fable", percent: 10, resetsAt: scopeResetsAt, role: .scoped),
            ],
            fetchedAt: try date("2026-08-04T07:48:00Z")
        )
    }

    private func builtRows(_ snapshot: ProviderSnapshot) throws -> [MenuRow] {
        MenuModel.rows(
            for: .loaded(snapshot), provider: .anthropic, now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )
    }

    @Test func rowsCarryTheirSeverity() throws {
        let rows = try builtRows(try snapshot(sessionPercent: 92, weekPercent: 80, scopeResetsAt: nil))

        #expect(rows[0].severity == .critical)   // session 92
        #expect(rows[1].severity == .warning)    // week 80
        #expect(rows[2].severity == .normal)     // Fable 10
    }
}

// MARK: - Multi-provider segments and sectioned rows

extension MenuModelTests {
    private func loaded(_ provider: Provider, _ percent: Int, plan: String? = nil) throws -> UsageState {
        .loaded(ProviderSnapshot(
            provider: provider,
            planName: plan,
            windows: [UsageWindow(label: "Session (5h)", percent: percent, resetsAt: nil, role: .primary)],
            fetchedAt: try date("2026-08-04T07:48:00Z")
        ))
    }

    @Test func buildsOneSegmentPerAvailableProvider() throws {
        let segments = MenuModel.statusSegments(for: [
            (.anthropic, try loaded(.anthropic, 37)),
            (.codex, try loaded(.codex, 4)),
        ])

        #expect(segments.count == 2)
        #expect(segments[0].provider == .anthropic)
        #expect(segments[0].text == "37%")
        #expect(segments[1].provider == .codex)
        #expect(segments[1].text == "4%")
    }

    @Test func omitsAProviderThatIsNotSignedIn() throws {
        let segments = MenuModel.statusSegments(for: [
            (.anthropic, try loaded(.anthropic, 37)),
            (.codex, .noToken),
        ])

        #expect(segments.count == 1)
        #expect(segments[0].provider == .anthropic)
    }

    @Test func fallsBackToADashWhenNoProviderHasAValue() {
        let segments = MenuModel.statusSegments(for: [(.anthropic, .noToken), (.codex, .noToken)])

        #expect(segments.count == 1)
        #expect(segments[0].text == "—")
        #expect(segments[0].percent == nil)
        // Markless and providerless: neither provider's mark should be drawn
        // for the placeholder, since neither is specifically the one that's
        // unavailable. See `AppKitTray.renderTitle`.
        #expect(segments[0].provider == nil)
    }

    @Test func marksACriticalSegmentIndependently() throws {
        let segments = MenuModel.statusSegments(for: [
            (.anthropic, try loaded(.anthropic, 95)),
            (.codex, try loaded(.codex, 4)),
        ])

        #expect(segments[0].isCritical)
        #expect(!segments[1].isCritical)
    }

    @Test func headsEachProviderSectionWithItsName() throws {
        let rows = MenuModel.rows(
            for: [(.anthropic, try loaded(.anthropic, 37)), (.codex, try loaded(.codex, 4, plan: "free"))],
            now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )

        let headers = rows.filter(\.isSectionHeader)
        #expect(headers.count == 2)
        #expect(headers[0].label == "CLAUDE")
        #expect(headers[1].label == "CODEX · free")
    }

    @Test func doesNotHeadASingleProviderSection() throws {
        // With only one provider configured the heading is noise.
        let rows = MenuModel.rows(
            for: [(.anthropic, try loaded(.anthropic, 37))],
            now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )
        #expect(rows.filter(\.isSectionHeader).isEmpty)
    }

    @Test func showsEachProvidersErrorUnderItsOwnHeading() throws {
        let rows = MenuModel.rows(
            for: [(.anthropic, try loaded(.anthropic, 37)), (.codex, .noToken)],
            now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )
        let labels = rows.map(\.label)
        #expect(labels.contains { $0.contains("Not signed in") })
    }
}

// MARK: - composedLabel
//
// Shared by the Linux menu-bar label (`AppIndicatorTray`) and the Windows
// tray tooltip (`Win32Tray`), so both name providers identically. Lifted here
// so it is unit-testable on every platform rather than only by hand on
// Linux/Windows.

extension MenuModelTests {
    @Test func composedLabelNamesTheOnlySignedInProvider() {
        let segments = [
            StatusSegment(provider: .codex, text: "8%", percent: 8, isCritical: false, isStale: false),
        ]
        #expect(MenuModel.composedLabel(for: segments) == "Codex 8%")
    }

    @Test func composedLabelNamesBothProviders() {
        let segments = [
            StatusSegment(provider: .anthropic, text: "37%", percent: 37, isCritical: false, isStale: false),
            StatusSegment(provider: .codex, text: "8%", percent: 8, isCritical: false, isStale: false),
        ]
        #expect(MenuModel.composedLabel(for: segments) == "Claude 37% · Codex 8%")
    }

    @Test func composedLabelOmitsAProviderNameForThePlaceholderSegment() {
        let segments = [
            StatusSegment(provider: nil, text: "—", percent: nil, isCritical: false, isStale: false),
        ]
        #expect(MenuModel.composedLabel(for: segments) == "—")
    }
}
