import AppKit
import ClaudeUsageCore
import ClaudeUsageTokens

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private var policy = UsageRefreshPolicy()
    private let client = UsageClient(tokens: KeychainTokenStore())

    private var pollTask: Task<Void, Never>?
    private var isFetching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        controller.onRefreshRequested = { [weak self] in self?.refreshNow() }
        self.controller = controller

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.policy.interval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
    }

    /// Fires an out-of-band refresh without disturbing the polling loop.
    /// Called from "Refresh Now" and menu-open — resets any backoff so a
    /// user-initiated retry isn't stuck on a backed-off interval.
    private func refreshNow() {
        policy.forceRefreshRequested()
        Task { [weak self] in
            await self?.refresh()
        }
    }

    /// Single guarded entry point: at most one fetch is ever in flight,
    /// whether it was triggered by the poll loop, "Refresh Now", or
    /// opening the menu. If one is already running, this call is a no-op.
    private func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        do {
            policy.record(success: try await client.fetchUsage())
        } catch let error as UsageError {
            policy.record(failure: error)
        } catch {
            policy.record(failure: .transport)
        }
        controller?.update(state: policy.state)
    }
}
