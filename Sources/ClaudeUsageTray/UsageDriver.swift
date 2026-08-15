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
    private let client: any UsageFetching
    private let loginItem: any LoginItemControlling

    private let lock = NSLock()
    private var policy = UsageRefreshPolicy()
    private var isFetching = false
    /// The last `UsageState` actually handed to the tray. Compared against the
    /// current state on every non-forced publish so a poll that produces no
    /// change doesn't rebuild the tray under the user's cursor.
    private var lastPublishedState: UsageState?

    public init(tray: any TrayBackend, client: any UsageFetching, loginItem: any LoginItemControlling) {
        self.tray = tray
        self.client = client
        self.loginItem = loginItem
    }

    public func makeHandlers() -> TrayHandlers {
        TrayHandlers(
            refresh: { [weak self] in self?.refreshNow() },
            toggleLoginItem: { [weak self] in
                guard let self else { return }
                self.loginItem.setEnabled(!self.loginItem.isEnabled)
                // Forced: the login-item flag changed even though `policy.state`
                // didn't, so a state-equality check would wrongly suppress this.
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
                await self.refresh()
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
    /// in `UsageDriverTests`, without going through fire-and-forget handler
    /// closures. Not part of the type's public API.
    var currentInterval: TimeInterval {
        withLock { policy.interval }
    }

    /// Out-of-band refresh from "Refresh Now" or menu-open. Resets any backoff
    /// so a user-initiated retry isn't stuck on a backed-off interval. Never
    /// called from the poll loop itself.
    func refreshNow() {
        withLock { policy.forceRefreshRequested() }
        Task.detached { [weak self] in await self?.refresh() }
    }

    /// At most one fetch is ever in flight, whether triggered by the poll loop,
    /// "Refresh Now", or opening the menu. If one is running, this is a no-op.
    func refresh() async {
        let shouldFetch = withLock {
            if isFetching { return false }
            isFetching = true
            return true
        }
        guard shouldFetch else { return }

        defer {
            withLock { isFetching = false }
        }

        do {
            let snapshot = try await client.fetchUsage()
            withLock { policy.record(success: snapshot) }
        } catch let error as UsageError {
            withLock { policy.record(failure: error) }
        } catch {
            withLock { policy.record(failure: .transport) }
        }
        publish()
    }

    /// `force: false` (the default) skips `tray.update` entirely when the
    /// state hasn't changed since the last publish — the no-op suppression
    /// that stops a poll landing while the menu is open from flickering it.
    /// `force: true` always rebuilds and republishes, for the two cases where
    /// something the tray displays changed without `policy.state` changing:
    /// the menu is about to be drawn (relative reset times must be current)
    /// or the login-item flag was just toggled.
    private func publish(force: Bool = false) {
        let (state, shouldPublish) = withLock { () -> (UsageState, Bool) in
            let state = policy.state
            if !force, let last = lastPublishedState, last == state {
                return (state, false)
            }
            lastPublishedState = state
            return (state, true)
        }
        guard shouldPublish else { return }

        tray.update(TrayContent(
            title: MenuModel.statusTitle(for: state),
            rows: MenuModel.rows(
                for: state, now: Date(),
                calendar: .current, locale: .current, timeZone: .current
            ),
            loginItemEnabled: loginItem.isEnabled
        ))
    }
}
