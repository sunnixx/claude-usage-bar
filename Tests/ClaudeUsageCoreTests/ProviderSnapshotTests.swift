import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct ProviderSnapshotTests {
    private func window(_ label: String, _ percent: Int, scoped: Bool = false) -> UsageWindow {
        UsageWindow(label: label, percent: percent, resetsAt: nil, isScoped: scoped)
    }

    @Test func primaryIsTheFirstWindow() {
        let snapshot = ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [window("Session (5h)", 37), window("This week", 26)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        // The menu bar reads `primary` — for Anthropic that must stay the
        // five-hour session figure, not the highest window.
        #expect(snapshot.primary?.label == "Session (5h)")
        #expect(snapshot.primary?.percent == 37)
    }

    @Test func primaryIsNilWithoutWindows() {
        let snapshot = ProviderSnapshot(
            provider: .codex, planName: "free", windows: [], fetchedAt: Date()
        )
        #expect(snapshot.primary == nil)
    }

    @Test func providersHaveDisplayNames() {
        #expect(Provider.anthropic.displayName == "Claude")
        #expect(Provider.codex.displayName == "Codex")
    }
}
