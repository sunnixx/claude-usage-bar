import Foundation
import Testing
@testable import HeadroomCore

@Suite struct TrayContentTests {
    private func snapshot() throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [
                UsageWindow(
                    label: "Session (5h)", percent: 37,
                    resetsAt: try #require(ISO8601Flexible.date(from: "2026-08-04T09:00:00Z")),
                    role: .primary
                ),
                UsageWindow(
                    label: "This week", percent: 26,
                    resetsAt: try #require(ISO8601Flexible.date(from: "2026-08-08T07:00:00Z"))
                ),
                UsageWindow(label: "Fable", percent: 10, resetsAt: nil, role: .scoped),
            ],
            fetchedAt: try #require(ISO8601Flexible.date(from: "2026-08-04T07:48:00Z"))
        )
    }

    @Test func buildsContentFromStateAndLoginFlag() throws {
        let state = UsageState.loaded(try snapshot())
        let content = TrayContent(states: [(.anthropic, state)], loginItemEnabled: true)

        #expect(content.states.count == 1)
        #expect(content.states.first?.0 == .anthropic)
        #expect(content.loginItemEnabled)
    }

    @Test func equalityIgnoresNothingButStatesAndLoginFlag() throws {
        let state = UsageState.loaded(try snapshot())
        let a = TrayContent(states: [(.anthropic, state)], loginItemEnabled: true)
        let b = TrayContent(states: [(.anthropic, state)], loginItemEnabled: true)
        let differentLogin = TrayContent(states: [(.anthropic, state)], loginItemEnabled: false)

        #expect(a == b)
        #expect(a != differentLogin)
    }
}
