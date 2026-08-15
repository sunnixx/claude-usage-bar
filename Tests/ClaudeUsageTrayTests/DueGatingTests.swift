import ClaudeUsageCore
import Foundation
import Testing
@testable import ClaudeUsageTray

// MARK: - Test doubles

/// A controllable clock, injected via `UsageDriver`'s `now:` parameter so
/// due-time comparisons in these tests are deterministic — no real sleeping,
/// no wall-clock races. `@unchecked Sendable`: all mutation goes through
/// `lock`.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { self.current = date }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

private final class RecordingTray: TrayBackend, @unchecked Sendable {
    func run(handlers: TrayHandlers) -> Never { fatalError("not used in tests") }
    func update(_ content: TrayContent) {}
}

private struct StubLogin: LoginItemControlling {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) {}
}

/// Counts calls and always fails, for deterministic sequential use with
/// `pollTick()`/`refresh(_:)`, which the test awaits directly — no gating
/// needed since nothing suspends indefinitely.
private actor CountingFailingClient: UsageFetching {
    private(set) var callCount = 0
    func fetchUsage() async throws -> ProviderSnapshot {
        callCount += 1
        throw UsageError.transport
    }
}

/// Counts calls and always succeeds, for deterministic sequential use.
private actor CountingSucceedingClient: UsageFetching {
    private(set) var callCount = 0
    let provider: Provider
    init(_ provider: Provider) { self.provider = provider }

    func fetchUsage() async throws -> ProviderSnapshot {
        callCount += 1
        return ProviderSnapshot(
            provider: provider,
            planName: nil,
            windows: [UsageWindow(label: "w", percent: 10, resetsAt: nil, role: .primary)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

/// Succeeds, but suspends on a continuation the test controls, so
/// `refreshNow()` — which fires a detached, fire-and-forget task — can be
/// observed deterministically mid-flight instead of guessed at with a delay.
private actor GatedSucceedingClient: UsageFetching {
    private(set) var callCount = 0
    private var pendingFetch: CheckedContinuation<ProviderSnapshot, Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    let provider: Provider
    init(_ provider: Provider) { self.provider = provider }

    func fetchUsage() async throws -> ProviderSnapshot {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingFetch = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilGated() async {
        if pendingFetch != nil { return }
        await withCheckedContinuation { continuation in waiter = continuation }
    }

    func release() {
        pendingFetch?.resume(returning: ProviderSnapshot(
            provider: provider, planName: nil,
            windows: [UsageWindow(label: "w", percent: 5, resetsAt: nil, role: .primary)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        ))
        pendingFetch = nil
    }
}

/// Gated like `GatedSucceedingClient`, but the caller chooses success or
/// failure per call — needed to first back a provider off with real failures
/// and then, separately, hold a later call in flight.
private actor ControllableClient: UsageFetching {
    private(set) var callCount = 0
    private var pendingFetch: CheckedContinuation<ProviderSnapshot, Error>?
    private var waiter: CheckedContinuation<Void, Never>?

    func fetchUsage() async throws -> ProviderSnapshot {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingFetch = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilGated() async {
        if pendingFetch != nil { return }
        await withCheckedContinuation { continuation in waiter = continuation }
    }

    func release(with result: Result<ProviderSnapshot, Error>) {
        pendingFetch?.resume(with: result)
        pendingFetch = nil
    }
}

// MARK: - Tests

@Suite struct DueGatingTests {

    /// A provider's own backoff must actually govern its own request rate:
    /// on a tick where it isn't due yet, `pollTick()` must not fetch it, even
    /// though a healthy, due provider on the same tick is fetched. Deleting
    /// the due check in `pollTick()` (fetching every configured provider on
    /// every tick, as the driver did before this fix) makes this fail: Codex
    /// would be refetched a second time despite not being due until t=120.
    @Test func pollTickSkipsAProviderThatIsNotYetDue() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let anthropicClient = CountingSucceedingClient(.anthropic)
        let codexClient = CountingFailingClient()
        let driver = UsageDriver(
            tray: RecordingTray(),
            clients: [(.anthropic, anthropicClient), (.codex, codexClient)],
            loginItem: StubLogin(),
            now: { clock.now }
        )

        // Prime both providers once, as the first ever tick would: Anthropic
        // succeeds (interval stays at the 60s base, next due at t=60), Codex
        // fails (interval doubles to 120s, next due at t=120).
        await driver.pollTick()
        #expect(await anthropicClient.callCount == 1)
        #expect(await codexClient.callCount == 1)
        #expect(driver.intervalForTesting(.codex) == 120)

        // Advance to t=90: Anthropic is due (60 <= 90), Codex is not (120 > 90).
        clock.advance(by: 90)
        await driver.pollTick()

        #expect(await anthropicClient.callCount == 2, "healthy, due provider must be refreshed")
        #expect(
            await codexClient.callCount == 1,
            "backed-off provider not yet due must be left alone entirely"
        )
    }

    /// "Refresh Now" (and menu-open) must bypass the due gate: the whole
    /// point of a manual refresh is that the user gets one immediately,
    /// regardless of where that provider's own backoff currently stands.
    @Test func refreshNowRefreshesAProviderEvenWhenNotYetDue() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let anthropicClient = CountingSucceedingClient(.anthropic)
        let codexClient = GatedSucceedingClient(.codex)
        let driver = UsageDriver(
            tray: RecordingTray(),
            clients: [(.anthropic, anthropicClient), (.codex, codexClient)],
            loginItem: StubLogin(),
            now: { clock.now }
        )

        // Prime Codex so it has a future due time (t=60, since it just
        // succeeded at t=0 with the 60s base interval).
        async let priming: Void = driver.refresh(.codex)
        await codexClient.waitUntilGated()
        await codexClient.release()
        await priming
        #expect(await codexClient.callCount == 1)

        // Still well before t=60: a poll tick would correctly skip Codex.
        clock.advance(by: 10)

        // But "Refresh Now" must fetch it anyway.
        driver.refreshNow()
        await codexClient.waitUntilGated()
        #expect(await codexClient.callCount == 2, "refreshNow() must not honour nextDue")
        await codexClient.release()

        // refreshNow() also refreshed Anthropic (sequentially, ahead of Codex
        // in `clients` order) — nothing left dangling.
        #expect(await anthropicClient.callCount == 1)
    }

    /// A provider found due but skipped because its own fetch is already in
    /// flight (e.g. a slow "Refresh Now" against a struggling endpoint) must
    /// not be left "overdue" — otherwise `timeUntilNextWake()` keeps
    /// returning ~0 and `start()`'s loop spins hot until that fetch finishes.
    /// Deleting the `nextDue` bump on the in-flight-skip path in
    /// `refresh(_:)` (leaving the guard a plain early return) makes this
    /// assertion fail: `timeUntilNextWake()` would report 0, not a positive
    /// retry delay.
    @Test func pollTickSkipPathLeavesTheNextWakeStrictlyPositive() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let codexClient = GatedSucceedingClient(.codex)
        let driver = UsageDriver(
            tray: RecordingTray(),
            clients: [(.codex, codexClient)],
            loginItem: StubLogin(),
            now: { clock.now }
        )

        // Start a fetch that never completes until released — standing in
        // for a slow request still running against a struggling endpoint.
        async let inFlight: Void = driver.refresh(.codex)
        await codexClient.waitUntilGated()

        // A poll tick lands while that fetch is still running. Codex has no
        // recorded `nextDue` yet (it has never completed a refresh), so
        // `pollTick()` considers it due, calls `refresh(.codex)`, and must
        // hit the in-flight guard rather than starting a second fetch.
        await driver.pollTick()
        #expect(await codexClient.callCount == 1, "the single-in-flight guard must still hold")

        // Strictly greater than the floor, not merely non-zero: the
        // `minimumWakeInterval` floor alone would already make a bare `> 0`
        // check pass even with the skip-path bump deleted, silently hiding
        // the regression this test exists to catch.
        #expect(driver.timeUntilNextWake() > UsageDriver.minimumWakeInterval)

        await codexClient.release()
        await inFlight
    }

    /// Defence in depth: whatever the recorded due times say — including the
    /// "never refreshed yet" default, which treats every provider as overdue
    /// — the poll loop must never be told to sleep for zero seconds.
    @Test func timeUntilNextWakeNeverReturnsZeroEvenWhenEveryProviderIsOverdue() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let driver = UsageDriver(
            tray: RecordingTray(),
            clients: [
                (.anthropic, CountingSucceedingClient(.anthropic)),
                (.codex, CountingFailingClient()),
            ],
            loginItem: StubLogin(),
            now: { clock.now }
        )

        // No refresh has ever happened: both providers are "overdue" by
        // `nextDue`'s documented default (absent == due arbitrarily far in
        // the past).
        #expect(driver.timeUntilNextWake() > 0)

        // Advancing the clock can only make every provider "more" overdue —
        // still must never surface as a zero sleep.
        clock.advance(by: 10_000)
        #expect(driver.timeUntilNextWake() > 0)
    }

    /// The skip-path bump must only ever push `nextDue` later, never pull it
    /// earlier. A provider already on a long backoff, then skipped because a
    /// concurrent fetch for it is in flight, must keep its long due time —
    /// not have it shortened to the short in-flight retry delay.
    @Test func skipPathNeverPullsALongBackoffEarlier() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let codexClient = ControllableClient()
        let driver = UsageDriver(
            tray: RecordingTray(),
            clients: [(.codex, codexClient)],
            loginItem: StubLogin(),
            now: { clock.now }
        )

        // Two consecutive transport failures back Codex off from the 60s
        // base to 240s (60 -> 120 -> 240), setting nextDue = t=0 + 240 = 240.
        for _ in 0..<2 {
            async let attempt: Void = driver.refresh(.codex)
            await codexClient.waitUntilGated()
            await codexClient.release(with: .failure(UsageError.transport))
            await attempt
        }
        #expect(driver.intervalForTesting(.codex) == 240)
        #expect(driver.timeUntilNextWake() == 240)

        // A third fetch starts and is left in flight...
        async let inFlight: Void = driver.refresh(.codex)
        await codexClient.waitUntilGated()
        #expect(await codexClient.callCount == 3)

        // ...and a concurrent call for the same provider arrives while it's
        // still running (e.g. refreshNow() from a menu-open racing the poll
        // loop). This must hit the skip branch, not start a fourth fetch.
        await driver.refresh(.codex)
        #expect(await codexClient.callCount == 3, "the skip must not start a new fetch")

        // The point of this test: nextDue must still reflect the 240s
        // backoff, not have been pulled in to the 5s in-flight retry delay.
        // Reverting the skip branch's `max(nextDue[provider] ?? retryAt,
        // retryAt)` to an unconditional `nextDue[provider] = retryAt` makes
        // this fail: timeUntilNextWake() would report ~5, not 240.
        #expect(driver.timeUntilNextWake() == 240)

        await codexClient.release(with: .failure(UsageError.transport))
        await inFlight
    }
}
