import ClaudeUsageCore
import Foundation

/// Owns the poll loop and the refresh policy. Knows nothing about any platform:
/// it talks to a `TrayBackend` and a `LoginItemControlling` and nothing else.
/// Lives in `ClaudeUsageTray` (not `ClaudeUsageBar`) specifically so it is
/// compiled — and testable — on every platform, not just macOS: this file is
/// the one place the single-in-flight guarantee is enforced, and the two
/// unrunnable backends (Linux, Windows) run this exact code unmodified.
public final class UsageDriver: @unchecked Sendable {
    private let tray: any TrayBackend
    private let clients: [(Provider, any UsageFetching)]
    private let loginItem: any LoginItemControlling

    private let lock = NSLock()
    /// One state machine per provider — its own backoff, its own staleness,
    /// its own auth-failure tolerance — so one provider's trouble can never
    /// bleed into another's reading.
    private var policies: [Provider: UsageRefreshPolicy]
    /// Which providers currently have a fetch in flight. Keyed by provider so
    /// two different providers may fetch concurrently, but never two fetches
    /// of the same provider at once.
    private var fetching: Set<Provider> = []
    /// The instant each provider becomes eligible for its next poll-loop
    /// fetch, set to `now() + policy.interval` right after any refresh of
    /// that provider completes (poll-triggered or not). A provider absent
    /// from this dictionary (never yet refreshed) is due immediately. This is
    /// what makes a backed-off provider's own `interval` actually govern its
    /// own request rate — see `pollTick()`.
    private var nextDue: [Provider: Date] = [:]
    /// Test seam only: production always uses the default, which reads the
    /// wall clock exactly as before. Tests inject a controllable clock so
    /// due-time comparisons are deterministic instead of racing real time.
    private let now: @Sendable () -> Date

    /// How soon `pollTick()` retries a provider it found due but skipped
    /// because a fetch was already in flight for it (e.g. a slow "Refresh
    /// Now" still running against a struggling endpoint). Without this, a
    /// skipped provider's `nextDue` stays in the past, `timeUntilNextWake()`
    /// keeps returning ~0, and the poll loop spins continuously until the
    /// in-flight fetch finishes. A few seconds is long enough to stop the
    /// spin but short enough that the provider is re-attempted promptly once
    /// the in-flight fetch clears. Must stay strictly greater than
    /// `minimumWakeInterval` — nothing enforces that ordering, but if it ever
    /// stopped holding, the skip-path test that distinguishes this bump from
    /// the floor alone would silently pass for the wrong reason again.
    /// Internal rather than private so `DueGatingTests` can assert the
    /// skip-path bump lands strictly above the `minimumWakeInterval` floor —
    /// distinguishing "the bump happened" from "the floor alone happened to
    /// cover for it". Not part of the type's public API.
    static let inFlightRetryInterval: TimeInterval = 5
    /// The floor `timeUntilNextWake()` never sleeps below, regardless of what
    /// the due times say. Defence in depth alongside the skip-path bump
    /// above: even a future bug that leaves some `nextDue` in the past can't
    /// turn the poll loop into a zero-sleep spin.
    /// Internal rather than private — see `inFlightRetryInterval`'s doc
    /// comment; tests need this value to assert against, not just a bare
    /// zero check.
    static let minimumWakeInterval: TimeInterval = 1

    /// Guards the publish decision and the `tray.update` call as a single
    /// atomic unit — separate from `lock`, which guards `policies`/`fetching`
    /// and is taken and released many times per fetch. Two concurrent
    /// `publish()` calls (e.g. a `refresh()` completion racing a menu-open) must
    /// not be able to interleave: without this, the newer state could win the
    /// race to update `lastPublishedState` while the older state's `tray.update`
    /// call lands after it, leaving the tray showing stale content that a
    /// subsequent equal-state publish would then wrongly suppress. Always
    /// acquired before `lock` when both are needed (`publish()` reads
    /// `policies` via `withLock` while holding `publishLock`), never the
    /// reverse, so the two locks can't deadlock against each other.
    private let publishLock = NSLock()
    /// The last `TrayContent` actually handed to the tray. Guarded by
    /// `publishLock`, not `lock` — see above.
    private var lastPublishedState: TrayContent?

    public init(
        tray: any TrayBackend,
        clients: [(Provider, any UsageFetching)],
        loginItem: any LoginItemControlling,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tray = tray
        self.clients = clients
        self.loginItem = loginItem
        self.policies = Dictionary(
            uniqueKeysWithValues: clients.map { ($0.0, UsageRefreshPolicy()) }
        )
        self.now = now
    }

    public func makeHandlers() -> TrayHandlers {
        TrayHandlers(
            refresh: { [weak self] in self?.refreshNow() },
            toggleLoginItem: { [weak self] in
                guard let self else { return }
                self.loginItem.setEnabled(!self.loginItem.isEnabled)
                // Forced: the login-item flag changed even though no
                // `policy.state` did, so a state-equality check would wrongly
                // suppress this.
                self.publish(force: true)
            },
            menuWillOpen: { [weak self] in
                guard let self else { return }
                // Rebuild synchronously, before asking for fresh data, so the
                // relative reset times ("in 1h 12m") and the Launch-at-Login
                // checkmark are current the instant the menu is drawn — not
                // whenever the in-flight or next poll happens to land. This
                // must run whether or not a fetch is already in flight, which
                // is why it doesn't go through `refresh()`.
                self.publish(force: true)
                self.refreshNow()
            }
        )
    }

    public func start() {
        publish()
        Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollTick()
                try? await Task.sleep(for: .seconds(self.timeUntilNextWake()))
            }
        }
    }

    /// Runs `body` while holding `lock`. Kept as a synchronous, non-async
    /// function so `refresh()` — which is `async` — never calls `lock.lock()`
    /// / `lock.unlock()` directly from an asynchronous context; the lock is
    /// still held for the same short critical sections as before, just via
    /// one indirection.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Internal rather than private — `@testable import` reaches this to drive
    /// and observe the poll/backoff machinery directly and deterministically
    /// in the driver tests. Not part of the type's public API. The minimum
    /// across providers' own backoff intervals — a raw policy reading, not a
    /// due-time computation; see `timeUntilNextWake()` for what the real poll
    /// loop actually sleeps on.
    var currentInterval: TimeInterval {
        withLock { policies.values.map(\.interval).min() ?? UsageRefreshPolicy.baseInterval }
    }

    /// What `start()`'s poll loop actually sleeps for between ticks: the
    /// smallest remaining time until any provider becomes due, floored at
    /// `minimumWakeInterval` so no due-time bookkeeping bug can ever turn
    /// this into a zero-sleep spin. This is what decouples "how often the
    /// loop wakes" from "which providers it fetches" — the loop can wake
    /// early for an eager provider without that forcing a backed-off
    /// provider to be fetched too; that decision is `pollTick()`'s due check.
    ///
    /// Internal, not private — `@testable import` reaches this so tests can
    /// assert the floor holds even when every provider is overdue.
    func timeUntilNextWake() -> TimeInterval {
        withLock {
            let now = self.now()
            let remaining = clients.map { provider, _ in
                max(0, (nextDue[provider] ?? .distantPast).timeIntervalSince(now))
            }
            let soonest = remaining.min() ?? UsageRefreshPolicy.baseInterval
            return max(soonest, Self.minimumWakeInterval)
        }
    }

    /// Test hook: exposes a single provider's backoff interval.
    func intervalForTesting(_ provider: Provider) -> TimeInterval {
        withLock { policies[provider]?.interval ?? 0 }
    }

    /// One iteration of the poll loop: refreshes only the providers that are
    /// currently due, per each provider's own `nextDue` time. A provider that
    /// isn't due yet is left alone entirely — no fetch, no state change —
    /// until a later tick finds it due, or `refreshNow()` bypasses the gate
    /// outright. This is the per-provider throttle: without it, every
    /// provider would be fetched on every tick regardless of its own backoff,
    /// which is exactly the bug this gate exists to close.
    ///
    /// Internal, not private — `@testable import` drives this directly so
    /// tests can exercise a single tick deterministically, without the real
    /// loop's sleep.
    func pollTick() async {
        let due = withLock {
            let now = self.now()
            return clients.map(\.0).filter { (nextDue[$0] ?? .distantPast) <= now }
        }
        for provider in due {
            await refresh(provider)
        }
    }

    /// Test hook: drives one full round across every configured provider,
    /// bypassing the due check — like `refreshNow()`, but without resetting
    /// backoff — and without the poll loop's sleep.
    func refreshAllForTesting() async {
        for (provider, _) in clients {
            await refresh(provider)
        }
    }

    /// Out-of-band refresh from "Refresh Now" or menu-open. Resets any backoff
    /// so a user-initiated retry isn't stuck on a backed-off interval. Never
    /// called from the poll loop itself. Applies to every configured
    /// provider — a manual refresh means "retry everything now" — and, unlike
    /// `pollTick()`, ignores each provider's `nextDue`: a user asking for a
    /// refresh gets one regardless of where that provider's own backoff
    /// currently stands.
    func refreshNow() {
        withLock {
            for provider in policies.keys {
                policies[provider]?.forceRefreshRequested()
            }
        }
        Task.detached { [weak self] in
            guard let self else { return }
            for (provider, _) in self.clients {
                await self.refresh(provider)
            }
        }
    }

    /// At most one fetch is ever in flight per provider, whether triggered by
    /// the poll loop, "Refresh Now", or opening the menu. If one is already
    /// running for this provider, this is a no-op — except that it still
    /// pushes `nextDue` out by `inFlightRetryInterval`, so a provider skipped
    /// here isn't left permanently "overdue" (which would otherwise spin the
    /// poll loop hot until the in-flight fetch finishes; see
    /// `inFlightRetryInterval`'s doc comment). A different provider may still
    /// fetch concurrently. On an actual fetch, always bumps that provider's
    /// `nextDue` to `now() + policy.interval` afterwards, whatever triggered
    /// it — a manual refresh pushes out the next scheduled poll for that
    /// provider too, so one doesn't land redundantly right on top of the
    /// other.
    func refresh(_ provider: Provider) async {
        guard let client = clients.first(where: { $0.0 == provider })?.1 else { return }

        let shouldFetch = withLock {
            if fetching.contains(provider) {
                let retryAt = now().addingTimeInterval(Self.inFlightRetryInterval)
                // Only ever push the due time out. A provider on a long
                // backoff must not have it shortened just because a
                // concurrent fetch was skipped.
                nextDue[provider] = max(nextDue[provider] ?? retryAt, retryAt)
                return false
            }
            fetching.insert(provider)
            return true
        }
        guard shouldFetch else { return }

        defer {
            withLock { fetching.remove(provider) }
        }

        do {
            let snapshot = try await client.fetchUsage()
            withLock { policies[provider]?.record(success: snapshot) }
        } catch let error as UsageError {
            withLock { policies[provider]?.record(failure: error) }
        } catch {
            withLock { policies[provider]?.record(failure: .transport) }
        }
        withLock {
            let interval = policies[provider]?.interval ?? UsageRefreshPolicy.baseInterval
            nextDue[provider] = now().addingTimeInterval(interval)
        }
        publish()
    }

    /// `force: false` (the default) skips `tray.update` entirely when nothing
    /// the tray displays has changed since the last publish — the no-op
    /// suppression that stops a poll landing while the menu is open from
    /// flickering it. `force: true` always rebuilds and republishes, for the
    /// two cases where something the tray displays changed without any
    /// `policy.state` changing: the menu is about to be drawn (relative reset
    /// times must be current) or the login-item flag was just toggled.
    ///
    /// The dedupe check and the `tray.update` call are one atomic step under
    /// `publishLock`, so concurrent publishes can never reach `tray.update`
    /// out of order — see `publishLock`'s doc comment. This relies on
    /// `TrayBackend.update` being non-blocking and non-reentrant, per its
    /// contract.
    private func publish(force: Bool = false) {
        publishLock.lock()
        defer { publishLock.unlock() }

        let states: [(Provider, UsageState)] = withLock {
            clients.map { provider, _ in (provider, policies[provider]?.state ?? .loading) }
        }

        let content = TrayContent(states: states, loginItemEnabled: loginItem.isEnabled)

        if !force, let last = lastPublishedState, last == content {
            return
        }
        lastPublishedState = content
        tray.update(content)
    }
}
