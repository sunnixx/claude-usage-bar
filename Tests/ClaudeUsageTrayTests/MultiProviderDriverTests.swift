import ClaudeUsageCore
import Foundation
import Testing
@testable import ClaudeUsageTray

private final class RecordingTray: TrayBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _contents: [TrayContent] = []
    var contents: [TrayContent] { lock.lock(); defer { lock.unlock() }; return _contents }

    func run(handlers: TrayHandlers) -> Never { fatalError("not used in tests") }
    func update(_ content: TrayContent) {
        lock.lock(); _contents.append(content); lock.unlock()
    }
}

private struct FixedClient: UsageFetching {
    let result: Result<ProviderSnapshot, UsageError>
    func fetchUsage() async throws -> ProviderSnapshot { try result.get() }
}

private struct StubLogin: LoginItemControlling {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) {}
}

private func snapshot(_ provider: Provider, _ percent: Int) -> ProviderSnapshot {
    ProviderSnapshot(
        provider: provider,
        planName: nil,
        // `role: .primary` is required: `ProviderSnapshot.primary` (and hence
        // `UsageState.displayPercent`) selects by role, not array position
        // (see commit 0931bd4), which postdates this brief's original text.
        windows: [UsageWindow(label: "w", percent: percent, resetsAt: nil, role: .primary)],
        fetchedAt: Date(timeIntervalSince1970: 100)
    )
}

@Suite struct MultiProviderDriverTests {
    @Test func oneProviderFailingLeavesTheOtherUntouched() async {
        let tray = RecordingTray()
        let driver = UsageDriver(
            tray: tray,
            clients: [
                (.anthropic, FixedClient(result: .success(snapshot(.anthropic, 37)))),
                (.codex, FixedClient(result: .failure(.noToken))),
            ],
            loginItem: StubLogin()
        )

        await driver.refreshAllForTesting()

        let latest = try? #require(tray.contents.last)
        let anthropic = latest?.states.first { $0.0 == .anthropic }?.1
        let codex = latest?.states.first { $0.0 == .codex }?.1

        // Codex being signed out must not disturb the Claude reading.
        #expect(anthropic?.displayPercent == 37)
        #expect(codex?.displayPercent == nil)
    }

    @Test func eachProviderBacksOffIndependently() async {
        let tray = RecordingTray()
        let driver = UsageDriver(
            tray: tray,
            clients: [
                (.anthropic, FixedClient(result: .success(snapshot(.anthropic, 37)))),
                (.codex, FixedClient(result: .failure(.transport))),
            ],
            loginItem: StubLogin()
        )

        await driver.refreshAllForTesting()
        await driver.refreshAllForTesting()

        // Claude succeeded twice so stays at the base interval; Codex failed
        // twice so has backed off. One shared interval could not express this.
        #expect(driver.intervalForTesting(.anthropic) == UsageRefreshPolicy.baseInterval)
        #expect(driver.intervalForTesting(.codex) > UsageRefreshPolicy.baseInterval)
    }
}
