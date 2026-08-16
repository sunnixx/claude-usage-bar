import Foundation
import Testing
@testable import HeadroomCore

@Suite struct FormattingTests {
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

    // MARK: percentText

    @Test func formatsAPercentage() {
        #expect(Formatting.percentText(37) == "37%")
    }

    @Test func showsADashWhenThereIsNoValue() {
        #expect(Formatting.percentText(nil) == "—")
    }

    // MARK: isCritical

    @Test(arguments: [(89, false), (90, true), (100, true)])
    func flagsCriticalAtNinetyPercent(percent: Int, expected: Bool) {
        #expect(Formatting.isCritical(percent) == expected)
    }

    @Test func absentValueIsNotCritical() {
        #expect(Formatting.isCritical(nil) == false)
    }

    // MARK: progressBar

    @Test func drawsAProportionalBar() {
        #expect(Formatting.progressBar(percent: 37, width: 10) == "▓▓▓▓░░░░░░")
        #expect(Formatting.progressBar(percent: 0, width: 10) == "░░░░░░░░░░")
        #expect(Formatting.progressBar(percent: 100, width: 10) == "▓▓▓▓▓▓▓▓▓▓")
    }

    @Test func clampsOutOfRangePercentages() {
        #expect(Formatting.progressBar(percent: -5, width: 10) == "░░░░░░░░░░")
        #expect(Formatting.progressBar(percent: 140, width: 10) == "▓▓▓▓▓▓▓▓▓▓")
    }

    @Test func clampsANegativeWidthToZeroInsteadOfTrapping() {
        #expect(Formatting.progressBar(percent: 50, width: -3) == "")
        #expect(Formatting.progressBar(percent: 50, width: 0) == "")
    }

    // MARK: resetDescription

    @Test func describesNearResetsRelatively() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let reset = try date("2026-08-04T09:00:00Z")

        #expect(
            Formatting.resetDescription(reset, now: now, calendar: calendar, locale: locale)
                == "resets in 1h 12m"
        )
    }

    @Test func omitsHoursWhenUnderAnHour() throws {
        let now = try date("2026-08-04T08:48:00Z")
        let reset = try date("2026-08-04T09:00:00Z")

        #expect(
            Formatting.resetDescription(reset, now: now, calendar: calendar, locale: locale)
                == "resets in 12m"
        )
    }

    @Test func collapsesSubMinuteResets() throws {
        let now = try date("2026-08-04T08:59:30Z")
        let reset = try date("2026-08-04T09:00:00Z")

        #expect(
            Formatting.resetDescription(reset, now: now, calendar: calendar, locale: locale)
                == "resets in under a minute"
        )
    }

    @Test func reportsElapsedResetsAsImminent() throws {
        let now = try date("2026-08-04T09:00:01Z")
        let reset = try date("2026-08-04T09:00:00Z")

        #expect(
            Formatting.resetDescription(reset, now: now, calendar: calendar, locale: locale)
                == "resetting now"
        )
    }

    @Test func switchesToAbsoluteAtTwentyFourHours() throws {
        let now = try date("2026-08-04T07:00:00Z")

        // 23h59m away — still relative.
        let near = try date("2026-08-05T06:59:00Z")
        #expect(
            Formatting.resetDescription(near, now: now, calendar: calendar, locale: locale)
                == "resets in 23h 59m"
        )

        // Exactly 24h away — absolute.
        let far = try date("2026-08-05T07:00:00Z")
        #expect(
            Formatting.resetDescription(far, now: now, calendar: calendar, locale: locale)
                == "resets Wed, Aug 5"
        )
    }

    @Test func hasNoDescriptionWithoutADate() throws {
        let now = try date("2026-08-04T07:00:00Z")
        #expect(Formatting.resetDescription(nil, now: now, calendar: calendar, locale: locale) == nil)
    }

    // MARK: clockTime

    @Test func formatsAClockTime() throws {
        let moment = try date("2026-08-04T12:04:00Z")
        #expect(Formatting.clockTime(moment, locale: locale, timeZone: utc) == "12:04")
    }
}

// MARK: - Severity

extension FormattingTests {
    @Test(arguments: [0, 1, 50, 74])
    func treatsUsageBelowSeventyFiveAsNormal(percent: Int) {
        #expect(Formatting.severity(for: percent) == .normal)
    }

    @Test(arguments: [75, 80, 89])
    func treatsUsageFromSeventyFiveAsWarning(percent: Int) {
        #expect(Formatting.severity(for: percent) == .warning)
    }

    @Test(arguments: [90, 99, 100, 140])
    func treatsUsageFromNinetyAsCritical(percent: Int) {
        #expect(Formatting.severity(for: percent) == .critical)
    }

    @Test func severityBoundariesAreExact() {
        // The thresholds are the whole point — pin both edges.
        #expect(Formatting.severity(for: 74) == .normal)
        #expect(Formatting.severity(for: 75) == .warning)
        #expect(Formatting.severity(for: 89) == .warning)
        #expect(Formatting.severity(for: 90) == .critical)
    }

    @Test func criticalSeverityAgreesWithIsCritical() {
        // isCritical still drives the menu bar title colour; the two must not drift.
        for percent in [0, 74, 75, 89, 90, 100] {
            #expect((Formatting.severity(for: percent) == .critical) == Formatting.isCritical(percent))
        }
    }
}
