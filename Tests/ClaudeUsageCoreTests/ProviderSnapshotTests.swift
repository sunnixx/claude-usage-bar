import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct ProviderSnapshotTests {
    private func window(_ label: String, _ percent: Int, role: WindowRole = .secondary) -> UsageWindow {
        UsageWindow(label: label, percent: percent, resetsAt: nil, role: role)
    }

    @Test func primaryIsTheFirstWindowWhenItIsAlsoThePrimaryRole() {
        let snapshot = ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [window("Session (5h)", 37, role: .primary), window("This week", 26)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        // The menu bar reads `primary` — for Anthropic that must stay the
        // five-hour session figure, not the highest window.
        #expect(snapshot.primary?.label == "Session (5h)")
        #expect(snapshot.primary?.percent == 37)
    }

    @Test func primaryIsSelectedByRoleNotPosition() {
        // The primary-role window is second in the array — `primary` must
        // still find it, because array position is not what decides it.
        let snapshot = ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [window("This week", 26), window("Session (5h)", 37, role: .primary)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(snapshot.primary?.label == "Session (5h)")
        #expect(snapshot.primary?.percent == 37)
    }

    @Test func primaryIsNilWhenNoWindowIsPrimary() {
        // A provider can report a weekly window with no session window (e.g.
        // Anthropic when `five_hour` is null and no `session` limit exists).
        // The menu bar must show "—" in that case rather than silently
        // presenting the weekly figure as if it were the session one.
        let snapshot = ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [window("This week", 26), window("Fable", 10, role: .scoped)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(snapshot.primary == nil)
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
