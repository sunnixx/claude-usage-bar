import AppKit
import ClaudeUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private var policy = UsageRefreshPolicy()
    private let client = UsageClient(tokens: KeychainTokenStore())

    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

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
        refreshTask?.cancel()
    }

    /// Fires an out-of-band refresh without disturbing the polling loop.
    private func refreshNow() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.refreshTask = nil
        }
    }

    private func refresh() async {
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
