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

    private func scopedWindows(_ snapshot: ProviderSnapshot) -> [UsageWindow] {
        snapshot.windows.filter(\.isScoped)
    }

    @Test func decodesFullResponse() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("full"), fetchedAt: fetchedAt)

        #expect(snapshot.provider == .anthropic)
        #expect(snapshot.windows[0].label == "Session (5h)")
        #expect(snapshot.windows[0].percent == 37)
        #expect(snapshot.windows[0].resetsAt == ISO8601Flexible.date(from: "2026-08-04T09:00:00Z"))
        #expect(snapshot.windows[1].label == "This week")
        #expect(snapshot.windows[1].percent == 26)
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func decodesPerModelScopes() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("full"), fetchedAt: fetchedAt)

        let scopes = scopedWindows(snapshot)
        #expect(scopes.count == 1)
        #expect(scopes.first?.label == "Fable")
        #expect(scopes.first?.percent == 10)
    }

    @Test func toleratesMissingScopesAndResetTimes() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("minimal"), fetchedAt: fetchedAt)

        #expect(snapshot.windows[0].percent == 4)
        #expect(snapshot.windows[0].resetsAt == nil)
        #expect(snapshot.windows[1].percent == 0)
        #expect(scopedWindows(snapshot).isEmpty)
    }

    @Test func fallsBackToTopLevelWindowsWhenLimitsAbsent() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("no-limits"), fetchedAt: fetchedAt)

        #expect(snapshot.windows[0].percent == 88)
        #expect(snapshot.windows[1].percent == 51)
        #expect(scopedWindows(snapshot).isEmpty)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            try UsageSnapshot.decode(from: Data("{nope".utf8), fetchedAt: fetchedAt)
        }
    }

    // MARK: - Scope-reset de-duplication
    //
    // A per-model scope that resets at the same instant as the weekly window
    // doesn't need to repeat that date — the weekly row above already shows it.
    // This moved here from MenuModelTests: it's a property of the decoded
    // data, not of the presentation.

    private func payload(json: String) throws -> UsageSnapshot.Payload {
        try JSONDecoder().decode(UsageSnapshot.Payload.self, from: Data(json.utf8))
    }

    @Test func omitsAScopeResetThatRepeatsTheWeeklyOne() throws {
        let shared = "2026-08-08T07:00:00Z"
        let decoded = try payload(json: """
        {
            "limits": [
                {"kind": "session", "percent": 37.0, "resets_at": "2026-08-04T09:00:00Z"},
                {"kind": "weekly_all", "percent": 26.0, "resets_at": "\(shared)"},
                {"kind": "weekly_scoped", "percent": 10.0, "resets_at": "\(shared)",
                 "scope": {"model": {"display_name": "Fable"}}}
            ]
        }
        """)
        let snapshot = UsageSnapshot.snapshot(from: decoded, fetchedAt: fetchedAt)

        let scope = try #require(scopedWindows(snapshot).first)
        #expect(scope.resetsAt == nil)
        #expect(snapshot.windows[1].resetsAt != nil, "the weekly row must still show it")
    }

    @Test func keepsAScopeResetThatDiffersFromTheWeeklyOne() throws {
        let decoded = try payload(json: """
        {
            "limits": [
                {"kind": "session", "percent": 37.0, "resets_at": "2026-08-04T09:00:00Z"},
                {"kind": "weekly_all", "percent": 26.0, "resets_at": "2026-08-08T07:00:00Z"},
                {"kind": "weekly_scoped", "percent": 10.0, "resets_at": "2026-08-09T07:00:00Z",
                 "scope": {"model": {"display_name": "Fable"}}}
            ]
        }
        """)
        let snapshot = UsageSnapshot.snapshot(from: decoded, fetchedAt: fetchedAt)

        let scope = try #require(scopedWindows(snapshot).first)
        #expect(scope.resetsAt != nil)
    }

    @Test func keepsAScopeResetWhenThereIsNoWeeklyWindow() throws {
        let decoded = try payload(json: """
        {
            "limits": [
                {"kind": "session", "percent": 37.0, "resets_at": "2026-08-04T09:00:00Z"},
                {"kind": "weekly_scoped", "percent": 10.0, "resets_at": "2026-08-08T07:00:00Z",
                 "scope": {"model": {"display_name": "Fable"}}}
            ]
        }
        """)
        let snapshot = UsageSnapshot.snapshot(from: decoded, fetchedAt: fetchedAt)

        let scope = try #require(scopedWindows(snapshot).first)
        #expect(scope.resetsAt != nil)
    }
}
