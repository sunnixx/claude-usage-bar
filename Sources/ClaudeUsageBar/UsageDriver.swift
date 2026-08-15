import ClaudeUsageCore
import ClaudeUsageTray
import Foundation

/// Owns the poll loop and the refresh policy. Knows nothing about any platform:
/// it talks to a `TrayBackend` and a `LoginItemControlling` and nothing else.
final class UsageDriver: @unchecked Sendable {
    private let tray: any TrayBackend
    private let client: any UsageFetching
    private let loginItem: any LoginItemControlling

    private let lock = NSLock()
    private var policy = UsageRefreshPolicy()
    private var isFetching = false

    init(tray: any TrayBackend, client: any UsageFetching, loginItem: any LoginItemControlling) {
        self.tray = tray
        self.client = client
        self.loginItem = loginItem
    }

    func makeHandlers() -> TrayHandlers {
        TrayHandlers(
            refresh: { [weak self] in self?.refreshNow() },
            toggleLoginItem: { [weak self] in
                guard let self else { return }
                self.loginItem.setEnabled(!self.loginItem.isEnabled)
                self.publish()
            },
            menuWillOpen: { [weak self] in self?.refreshNow() }
        )
    }

    func start() {
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

    private var currentInterval: TimeInterval {
        withLock { policy.interval }
    }

    /// Out-of-band refresh from "Refresh Now" or menu-open. Resets any backoff
    /// so a user-initiated retry isn't stuck on a backed-off interval.
    private func refreshNow() {
        withLock { policy.forceRefreshRequested() }
        Task.detached { [weak self] in await self?.refresh() }
    }

    /// At most one fetch is ever in flight, whether triggered by the poll loop,
    /// "Refresh Now", or opening the menu. If one is running, this is a no-op.
    private func refresh() async {
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

    private func publish() {
        let state = withLock { policy.state }

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
