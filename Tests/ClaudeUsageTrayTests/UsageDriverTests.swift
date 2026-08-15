import Foundation
import Testing
@testable import ClaudeUsageCore
@testable import ClaudeUsageTray

// MARK: - Test doubles

/// Records every `TrayContent` handed to it. `run` traps — nothing in this
/// suite drives the tray's own run loop, only `UsageDriver`'s poll/backoff
/// machinery.
private final class SpyTray: TrayBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [TrayContent] = []

    var updates: [TrayContent] {
        lock.lock()
        defer { lock.unlock() }
        return _updates
    }

    func run(handlers: TrayHandlers) -> Never {
        fatalError("SpyTray.run should never be called in UsageDriverTests")
    }

    func update(_ content: TrayContent) {
        lock.lock()
        _updates.append(content)
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
    private var pendingFetch: CheckedContinuation<UsageSnapshot, Error>?
    private var waiter: CheckedContinuation<Void, Never>?

    func fetchUsage() async throws -> UsageSnapshot {
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

    func release(with result: Result<UsageSnapshot, Error>) {
        pendingFetch?.resume(with: result)
        pendingFetch = nil
    }
}

/// A `UsageFetching` that always fails, for exercising backoff growth.
private actor FailingClient: UsageFetching {
    private(set) var callCount = 0

    func fetchUsage() async throws -> UsageSnapshot {
        callCount += 1
        throw UsageError.transport
    }
}

private func sampleSnapshot() throws -> UsageSnapshot {
    UsageSnapshot(
        session: UsageWindow(
            percent: 12,
            resetsAt: try #require(ISO8601Flexible.date(from: "2026-08-04T09:00:00Z"))
        ),
        week: nil,
        scopedWeekly: [],
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
        let driver = UsageDriver(tray: SpyTray(), client: gated, loginItem: StubLoginItem())

        async let concurrentRefreshes: Void = withTaskGroup(of: Void.self) { group in
            group.addTask { await driver.refresh() }
            group.addTask { await driver.refresh() }
            group.addTask { await driver.refresh() }
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
        async let next: Void = driver.refresh()
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
        let driver = UsageDriver(tray: SpyTray(), client: client, loginItem: StubLoginItem())

        await driver.refresh()
        await driver.refresh()

        #expect(await client.callCount == 2)
    }

    /// Only user-initiated refresh resets the backoff. Repeated poll-style
    /// failures must back off monotonically; `refreshNow()` — what "Refresh
    /// Now" and menu-open call — must reset to the base interval, and it must
    /// do so synchronously (before its own resulting fetch can complete),
    /// never as a side effect of the poll loop itself.
    @Test func onlyUserInitiatedRefreshResetsTheBackoff() async throws {
        let gated = GatedClient()
        let driver = UsageDriver(tray: SpyTray(), client: gated, loginItem: StubLoginItem())
        let base = await driver.currentInterval

        // Three poll-loop-style failures: interval must grow, never reset.
        for _ in 0..<3 {
            async let r: Void = driver.refresh()
            await gated.waitUntilGated()
            await gated.release(with: .failure(UsageError.transport))
            await r
        }
        let backedOff = await driver.currentInterval
        #expect(backedOff > base)

        // `refreshNow()` resets `policy.interval` synchronously, before the
        // detached task it spawns can touch the client — the client is still
        // gated, so nothing else can have changed the interval in between.
        driver.refreshNow()
        #expect(await driver.currentInterval == base)

        // Drain the fetch `refreshNow()` triggered so nothing is left dangling.
        await gated.waitUntilGated()
        await gated.release(with: .failure(UsageError.transport))
    }
}
