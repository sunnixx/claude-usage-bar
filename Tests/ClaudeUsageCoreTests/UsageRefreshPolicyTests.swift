import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct UsageRefreshPolicyTests {
    private func snapshot(percent: Int, at seconds: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(
            session: UsageWindow(percent: percent, resetsAt: nil),
            week: UsageWindow(percent: 10, resetsAt: nil),
            scopedWeekly: [],
            fetchedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func startsLoadingAtTheBaseInterval() {
        let policy = UsageRefreshPolicy()

        #expect(policy.state == .loading)
        #expect(policy.interval == 60)
    }

    @Test func recordsASuccessfulFetch() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)

        policy.record(success: fetched)

        #expect(policy.state == .loaded(fetched))
        #expect(policy.interval == 60)
    }

    @Test func backsOffOnRepeatedFailures() {
        var policy = UsageRefreshPolicy()

        policy.record(failure: .transport)
        #expect(policy.interval == 120)

        policy.record(failure: .transport)
        #expect(policy.interval == 240)

        policy.record(failure: .transport)
        #expect(policy.interval == 300)

        policy.record(failure: .transport)
        #expect(policy.interval == 300)
    }

    @Test func resetsTheIntervalOnSuccess() {
        var policy = UsageRefreshPolicy()
        policy.record(failure: .transport)
        policy.record(failure: .transport)

        policy.record(success: snapshot(percent: 5, at: 500))

        #expect(policy.interval == 60)
    }

    @Test func keepsTheLastValueWhenTheNetworkFails() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)
        policy.record(success: fetched)

        policy.record(failure: .transport)

        #expect(policy.state == .stale(fetched, since: Date(timeIntervalSince1970: 100)))
    }

    @Test func reportsUnreachableWhenNothingHasEverSucceeded() {
        var policy = UsageRefreshPolicy()

        policy.record(failure: .transport)

        #expect(policy.state == .unreachable)
    }

    @Test func dropsTheValueWhenTheTokenIsGone() {
        var policy = UsageRefreshPolicy()
        policy.record(success: snapshot(percent: 37, at: 100))

        policy.record(failure: .noToken)

        #expect(policy.state == .noToken)
    }

    @Test func dropsTheValueWhenTheTokenExpires() {
        var policy = UsageRefreshPolicy()
        policy.record(success: snapshot(percent: 37, at: 100))

        policy.record(failure: .unauthorized)

        #expect(policy.state == .unauthorized)
    }

    @Test func treatsBadStatusLikeATransportFailure() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)
        policy.record(success: fetched)

        policy.record(failure: .badStatus(503))

        #expect(policy.state == .stale(fetched, since: Date(timeIntervalSince1970: 100)))
    }

    @Test func recoversFromAStaleState() {
        var policy = UsageRefreshPolicy()
        policy.record(success: snapshot(percent: 37, at: 100))
        policy.record(failure: .transport)

        let fresh = snapshot(percent: 41, at: 200)
        policy.record(success: fresh)

        #expect(policy.state == .loaded(fresh))
        #expect(policy.interval == 60)
    }

    @Test func dropsValuePermanentlyOnNoToken() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)
        policy.record(success: fetched)

        policy.record(failure: .noToken)
        policy.record(failure: .transport)

        #expect(policy.state == .unreachable)
    }

    @Test func dropsValuePermanentlyOnUnauthorized() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)
        policy.record(success: fetched)

        policy.record(failure: .unauthorized)
        policy.record(failure: .transport)

        #expect(policy.state == .unreachable)
    }

    @Test func retainsTheLastValueOnKeychainUnavailable() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)
        policy.record(success: fetched)

        policy.record(failure: .keychainUnavailable)

        #expect(policy.state == .stale(fetched, since: Date(timeIntervalSince1970: 100)))
    }

    @Test func reportsKeychainDeniedWhenNothingHasEverSucceeded() {
        var policy = UsageRefreshPolicy()

        policy.record(failure: .keychainUnavailable)

        #expect(policy.state == .keychainDenied)
    }

    @Test func forceRefreshResetsTheIntervalWithoutTouchingState() {
        var policy = UsageRefreshPolicy()
        policy.record(failure: .transport)
        policy.record(failure: .transport)
        #expect(policy.interval == 240)

        policy.forceRefreshRequested()

        #expect(policy.interval == 60)
        #expect(policy.state == .unreachable)
    }

    @Test func recoversFromNoTokenWithFreshFetch() {
        var policy = UsageRefreshPolicy()
        policy.record(success: snapshot(percent: 37, at: 100))
        policy.record(failure: .noToken)

        let fresh = snapshot(percent: 42, at: 300)
        policy.record(success: fresh)

        #expect(policy.state == .loaded(fresh))
        #expect(policy.interval == 60)
    }
}
