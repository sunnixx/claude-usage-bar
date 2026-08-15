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
        loginItem: any LoginItemControlling
    ) {
        self.tray = tray
        self.clients = clients
        self.loginItem = loginItem
        self.policies = Dictionary(
            uniqueKeysWithValues: clients.map { ($0.0, UsageRefreshPolicy()) }
        )
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
                for (provider, _) in self.clients {
                    await self.refresh(provider)
                }
                try? await Task.sleep(for: .seconds(self.currentInterval))
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
    /// across providers, so the loop ticks often enough for the most eager one
    /// (a backed-off provider must never slow down a healthy one's polling).
    var currentInterval: TimeInterval {
        withLock { policies.values.map(\.interval).min() ?? UsageRefreshPolicy.baseInterval }
    }

    /// Test hook: exposes a single provider's backoff interval.
    func intervalForTesting(_ provider: Provider) -> TimeInterval {
        withLock { policies[provider]?.interval ?? 0 }
    }

    /// Test hook: drives one full round across every configured provider
    /// without the poll loop's sleep.
    func refreshAllForTesting() async {
        for (provider, _) in clients {
            await refresh(provider)
        }
    }

    /// Out-of-band refresh from "Refresh Now" or menu-open. Resets any backoff
    /// so a user-initiated retry isn't stuck on a backed-off interval. Never
    /// called from the poll loop itself. Applies to every configured
    /// provider — a manual refresh means "retry everything now".
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
    /// running for this provider, this is a no-op; a different provider may
    /// still fetch concurrently.
    func refresh(_ provider: Provider) async {
        guard let client = clients.first(where: { $0.0 == provider })?.1 else { return }

        let shouldFetch = withLock {
            if fetching.contains(provider) { return false }
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
        // Transitional: mirrors the first (Anthropic) provider's reading,
        // exactly as the old single-provider driver published it, until
        // Task 7 replaces these fields with multi-provider rendering.
        let primaryState = states.first?.1 ?? .loading

        let content = TrayContent(
            states: states,
            title: MenuModel.statusTitle(for: primaryState),
            rows: MenuModel.rows(
                for: primaryState, now: Date(),
                calendar: .current, locale: .current, timeZone: .current
            ),
            loginItemEnabled: loginItem.isEnabled
        )

        if !force, let last = lastPublishedState, last == content {
            return
        }
        lastPublishedState = content
        tray.update(content)
    }
}
