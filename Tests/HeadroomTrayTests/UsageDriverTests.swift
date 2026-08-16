import Foundation
import Testing
@testable import HeadroomCore
@testable import HeadroomTray

// MARK: - Test doubles

/// Records every `TrayContent` handed to it. `run` traps — nothing in this
/// suite drives the tray's own run loop, only `UsageDriver`'s poll/backoff
/// machinery.
private final class SpyTray: TrayBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [TrayContent] = []
    private var _forced: [Bool] = []

    var updates: [TrayContent] {
        lock.lock()
        defer { lock.unlock() }
        return _updates
    }

    /// Parallel to `updates`: the `force` flag `UsageDriver.publish()` passed
    /// alongside each corresponding `TrayContent`.
    var forced: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return _forced
    }

    func run(handlers: TrayHandlers) -> Never {
        fatalError("SpyTray.run should never be called in UsageDriverTests")
    }

    func update(_ content: TrayContent, force: Bool) {
        lock.lock()
        _updates.append(content)
        _forced.append(force)
        lock.unlock()
    }
}

private final class StubLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _isEnabled: Bool

    init(isEnabled: Bool = false) {
        self._isEnabled = isEnabled
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        _isEnabled = enabled
        lock.unlock()
    }
}

/// A `UsageFetching` whose `fetchUsage()` counts its calls, then suspends on
/// a continuation the test controls explicitly — so tests can assert "exactly
/// one call happened" and "the next call only happens after I say so" without
/// any sleep-based synchronization. An `actor` because the count and the
/// pending continuation are mutated from whichever task calls `fetchUsage()`.
private actor GatedClient: UsageFetching {
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

    /// Suspends until a call to `fetchUsage()` is in flight and waiting on
    /// `release(with:)`. Returns immediately if one is already waiting.
    func waitUntilGated() async {
        if pendingFetch != nil { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release(with result: Result<ProviderSnapshot, Error>) {
        pendingFetch?.resume(with: result)
        pendingFetch = nil
    }
}

/// A `UsageFetching` that always fails, for exercising backoff growth.
private actor FailingClient: UsageFetching {
    private(set) var callCount = 0

    func fetchUsage() async throws -> ProviderSnapshot {
        callCount += 1
        throw UsageError.transport
    }
}

private func sampleSnapshot() throws -> ProviderSnapshot {
    ProviderSnapshot(
        provider: .anthropic,
        planName: nil,
        windows: [
            UsageWindow(
                label: "Session (5h)", percent: 12,
                resetsAt: try #require(ISO8601Flexible.date(from: "2026-08-04T09:00:00Z")),
                role: .primary
            )
        ],
        fetchedAt: try #require(ISO8601Flexible.date(from: "2026-08-04T07:48:00Z"))
    )
}

// MARK: - Tests

@Suite struct UsageDriverTests {

    /// The poll loop, "Refresh Now", and menu-open all funnel through the same
    /// guard: whichever of several concurrent calls to `refresh()` gets there
    /// first is the only one that reaches the client. Firing three at once
    /// (standing in for one poll-loop tick racing two handler-triggered
    /// refreshes) must produce exactly one call, and the guard must release
    /// again afterwards so a later refresh isn't stuck no-op'ing forever.
    @Test func atMostOneFetchIsEverInFlight() async throws {
        let gated = GatedClient()
        let driver = UsageDriver(tray: SpyTray(), clients: [(.anthropic, gated)], loginItem: StubLoginItem())

        async let concurrentRefreshes: Void = withTaskGroup(of: Void.self) { group in
            group.addTask { await driver.refresh(.anthropic) }
            group.addTask { await driver.refresh(.anthropic) }
            group.addTask { await driver.refresh(.anthropic) }
        }

        // `isFetching` is set (under lock) before the winning call ever
        // awaits `fetchUsage()`, so by the time exactly one call has reached
        // the gate, the other two have already lost the race and returned —
        // whether or not they've been scheduled yet, they can only observe
        // `isFetching == true` until we release the gate below.
        await gated.waitUntilGated()
        #expect(await gated.callCount == 1)

        await gated.release(with: .success(try sampleSnapshot()))
        await concurrentRefreshes
        #expect(await gated.callCount == 1)

        // The guard must have been cleared: a fresh refresh fires again.
        async let next: Void = driver.refresh(.anthropic)
        await gated.waitUntilGated()
        #expect(await gated.callCount == 2)
        await gated.release(with: .success(try sampleSnapshot()))
        await next
    }

    /// `isFetching` must be cleared by the `defer` even when the fetch throws
    /// — otherwise one failed request would permanently wedge the app. Two
    /// sequential refreshes against a client that always throws must both
    /// reach the client.
    @Test func theInFlightGuardClearsEvenWhenTheFetchThrows() async {
        let client = FailingClient()
        let driver = UsageDriver(tray: SpyTray(), clients: [(.anthropic, client)], loginItem: StubLoginItem())

        await driver.refresh(.anthropic)
        await driver.refresh(.anthropic)

        #expect(await client.callCount == 2)
    }

    /// Only user-initiated refresh resets the backoff. Repeated poll-style
    /// failures must back off by exactly the policy's doubling schedule —
    /// captured after each one, not just checked once at the end, so that a
    /// spurious reset anywhere in the loop (e.g. `forceRefreshRequested()`
    /// mistakenly called from `refresh()` or the poll body instead of only
    /// from a user-initiated path) changes the observed sequence and fails
    /// the test, rather than being masked by the interval still ending up
    /// somewhere above the base. `refreshNow()` — what "Refresh Now" and
    /// menu-open call — must then reset it back to the base interval, and do
    /// so synchronously (before its own resulting fetch can complete), never
    /// as a side effect of the poll loop itself.
    ///
    /// This drives `refresh()` directly rather than `start()`'s real poll
    /// loop: `start()` waits on `Task.sleep(for: .seconds(currentInterval))`
    /// between iterations, and nothing in `UsageDriver` lets a test replace
    /// that clock, so exercising the loop itself deterministically — without
    /// a real wait of up to 300s per iteration — isn't possible without
    /// adding a clock/sleep seam to production code, which is out of scope
    /// here. What this test does cover is the exact method `start()`'s loop
    /// calls on every iteration (`refresh()`), and that it never resets
    /// backoff; `start()`'s own loop plumbing (sleep, then call `refresh()`
    /// again) is not separately exercised.
    @Test func onlyUserInitiatedRefreshResetsTheBackoff() async throws {
        let gated = GatedClient()
        let driver = UsageDriver(tray: SpyTray(), clients: [(.anthropic, gated)], loginItem: StubLoginItem())
        let base = await driver.currentInterval
        #expect(base == UsageRefreshPolicy.baseInterval)

        // Three poll-loop-style failures: capture the interval after each one.
        var observed: [TimeInterval] = []
        for _ in 0..<3 {
            async let r: Void = driver.refresh(.anthropic)
            await gated.waitUntilGated()
            await gated.release(with: .failure(UsageError.transport))
            await r
            observed.append(await driver.currentInterval)
        }
        // 60 -> 120 -> 240 -> 300 (the policy's max), doubling each time with
        // no reset in between.
        #expect(observed == [120, 240, 300])

        // `refreshNow()` resets `policy.interval` synchronously, before the
        // detached task it spawns can touch the client — the client is still
        // gated, so nothing else can have changed the interval in between.
        driver.refreshNow()
        #expect(await driver.currentInterval == base)

        // Drain the fetch `refreshNow()` triggered so nothing is left dangling.
        await gated.waitUntilGated()
        await gated.release(with: .failure(UsageError.transport))
    }

    /// `makeHandlers().menuWillOpen` calls `publish(force: true)`
    /// synchronously, precisely so the tray rebuilds with current relative
    /// reset captions when the menu is about to be drawn. Before this fix,
    /// `force` never reached `tray.update` at all — the driver's own dedupe
    /// let a forced publish through, but the value handed to the backend
    /// carried no signal that would let it bypass its own "unchanged, skip
    /// it" guard. This asserts `force` actually arrives at the backend.
    @Test func menuWillOpenPublishesWithForceTrue() async {
        let tray = SpyTray()
        let gated = GatedClient()
        let driver = UsageDriver(tray: tray, clients: [(.anthropic, gated)], loginItem: StubLoginItem())

        driver.makeHandlers().menuWillOpen()

        #expect(tray.forced.last == true)

        // `menuWillOpen` also calls `refreshNow()`, which fires a detached
        // fetch against `gated` — drain it so nothing is left dangling.
        await gated.waitUntilGated()
        await gated.release(with: .failure(UsageError.transport))
    }
}
