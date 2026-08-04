import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct ISO8601FlexibleTests {
    @Test func stripsSixDigitFractionalSeconds() {
        #expect(
            ISO8601Flexible.stripFractionalSeconds("2026-08-04T09:00:00.782828+00:00")
                == "2026-08-04T09:00:00+00:00"
        )
    }

    @Test func leavesTimestampsWithoutFractionsAlone() {
        #expect(
            ISO8601Flexible.stripFractionalSeconds("2026-08-04T09:00:00Z")
                == "2026-08-04T09:00:00Z"
        )
    }

    @Test func parsesFractionalTimestamp() throws {
        let parsed = try #require(ISO8601Flexible.date(from: "2026-08-04T09:00:00.782828+00:00"))
        let expected = try #require(ISO8601Flexible.date(from: "2026-08-04T09:00:00Z"))
        #expect(parsed == expected)
    }

    @Test func returnsNilForGarbage() {
        #expect(ISO8601Flexible.date(from: "not a date") == nil)
    }
}

@Suite struct UsageSnapshotTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_000_000)

    @Test func decodesFullResponse() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("full"), fetchedAt: fetchedAt)

        #expect(snapshot.session?.percent == 37)
        #expect(snapshot.week?.percent == 26)
        #expect(snapshot.session?.resetsAt == ISO8601Flexible.date(from: "2026-08-04T09:00:00Z"))
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func decodesPerModelScopes() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("full"), fetchedAt: fetchedAt)

        #expect(snapshot.scopedWeekly.count == 1)
        #expect(snapshot.scopedWeekly.first?.label == "Fable")
        #expect(snapshot.scopedWeekly.first?.percent == 10)
    }

    @Test func toleratesMissingScopesAndResetTimes() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("minimal"), fetchedAt: fetchedAt)

        #expect(snapshot.session?.percent == 4)
        #expect(snapshot.session?.resetsAt == nil)
        #expect(snapshot.week?.percent == 0)
        #expect(snapshot.scopedWeekly.isEmpty)
    }

    @Test func fallsBackToTopLevelWindowsWhenLimitsAbsent() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("no-limits"), fetchedAt: fetchedAt)

        #expect(snapshot.session?.percent == 88)
        #expect(snapshot.week?.percent == 51)
        #expect(snapshot.scopedWeekly.isEmpty)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            try UsageSnapshot.decode(from: Data("{nope".utf8), fetchedAt: fetchedAt)
        }
    }
}
