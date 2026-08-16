import Foundation
import Testing
@testable import HeadroomCore

@Suite struct CodexSnapshotTests {
    private let fetched = Date(timeIntervalSince1970: 1_789_000_000)

    @Test func decodesPrimaryAndSecondaryWindows() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-full"), fetchedAt: fetched)

        #expect(snapshot.provider == .codex)
        #expect(snapshot.planName == "pro")
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows[0].label == "5h")
        #expect(snapshot.windows[0].percent == 42)
        #expect(snapshot.windows[1].label == "This week")
        #expect(snapshot.windows[1].percent == 63)
    }

    @Test func primaryIsFirstSoTheMenuBarReadsIt() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-full"), fetchedAt: fetched)
        #expect(snapshot.primary?.percent == 42)
    }

    @Test func convertsEpochResetTimes() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-full"), fetchedAt: fetched)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_789_416_863))
    }

    @Test func handlesAFreePlanWithNoSecondaryWindow() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-free"), fetchedAt: fetched)

        #expect(snapshot.planName == "free")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].label == "30 days")
        #expect(snapshot.windows[0].percent == 0)
    }

    @Test func rendersAdditionalLimitsAsScopedRows() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-additional"), fetchedAt: fetched)

        let scoped = try #require(snapshot.windows.first { $0.isScoped })
        #expect(scoped.percent == 25)
        #expect(snapshot.windows.first?.isScoped == false)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            try CodexSnapshot.decode(from: Data("not json".utf8), fetchedAt: fetched)
        }
    }

    // Schema drift is distinct from a syntax error: every field in `Payload`
    // is Optional (deliberately, so plan-dependent fields can come and go),
    // which means a shape change decodes "successfully" unless `decode`
    // explicitly rejects an empty window list.

    @Test func throwsOnAnEmptyObjectRatherThanReturningAZeroedSnapshot() {
        #expect(throws: (any Error).self) {
            try CodexSnapshot.decode(from: Data("{}".utf8), fetchedAt: fetched)
        }
    }

    @Test func throwsWhenTheRateLimitKeyIsRenamed() {
        let json = """
        {
          "plan_type": "pro",
          "rate_limits": {
            "primary_window": { "used_percent": 42, "limit_window_seconds": 18000, "reset_at": 1789416863 }
          }
        }
        """
        #expect(throws: (any Error).self) {
            try CodexSnapshot.decode(from: Data(json.utf8), fetchedAt: fetched)
        }
    }

    @Test func throwsWhenThePrimaryWindowHasNoUsedPercent() {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": null, "limit_window_seconds": 18000, "reset_at": 1789416863 },
            "secondary_window": null
          }
        }
        """
        #expect(throws: (any Error).self) {
            try CodexSnapshot.decode(from: Data(json.utf8), fetchedAt: fetched)
        }
    }

    @Test func carriesNoPersonallyIdentifyingInformation() throws {
        // The response contains email, user_id and account_id. None of it may
        // survive decoding — the app has no use for it and must not hold it.
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-full"), fetchedAt: fetched)
        let rendered = "\(snapshot)"

        #expect(!rendered.contains("@"))
        #expect(!rendered.lowercased().contains("user-"))
        #expect(!rendered.contains("00000000-0000"))
    }

    @Test(arguments: [
        (3600, "1h"), (18000, "5h"), (86399, "24h"),
        (604800, "This week"), (86400, "1 days"), (2592000, "30 days"),
    ])
    func labelsWindowsFromTheirDuration(seconds: Int, expected: String) {
        #expect(CodexSnapshot.windowLabel(seconds: seconds) == expected)
    }
}
