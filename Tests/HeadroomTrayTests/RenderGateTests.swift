import HeadroomCore
import Testing
@testable import HeadroomTray

/// `RenderGate.shouldRender` is the "redraw, or skip as a no-op?" decision
/// shared by all three `TrayBackend`s. It replaces three copies of a
/// `next != shown` guard that — before this fix — had no way to bypass the
/// equality check at all: a menu-open rebuild always sets `force: true`
/// specifically because it just recomputed relative reset captions
/// ("resets in 2h 14m") from `Date()`, which `TrayContent`'s own equality
/// (states + login flag only) cannot see moving. Without the bypass, a
/// forced update for byte-identical `TrayContent` was silently swallowed by
/// the backend's own guard and the stale caption stayed on screen.
@Suite struct RenderGateTests {
    private func content(loginEnabled: Bool = true) -> TrayContent {
        TrayContent(states: [(.anthropic, .loading)], loginItemEnabled: loginEnabled)
    }

    @Test func unforcedUpdateIsSuppressedWhenContentCompareEqualToShown() {
        let shown = content()
        let next = content()

        #expect(!RenderGate.shouldRender(next, shownAs: shown, force: false))
    }

    @Test func unforcedUpdateStillRendersWhenContentDiffers() {
        let shown = content(loginEnabled: true)
        let next = content(loginEnabled: false)

        #expect(RenderGate.shouldRender(next, shownAs: shown, force: false))
    }

    /// The regression this whole fix exists for: a forced update must
    /// bypass the equality guard and render even though `next` compares
    /// equal to `shown` — this is exactly the menu-open case where the
    /// underlying `states` haven't changed but the relative captions the
    /// backend is about to recompute have.
    @Test func forcedUpdateRendersEvenWhenContentComparesEqualToShown() {
        let shown = content()
        let next = content()

        #expect(RenderGate.shouldRender(next, shownAs: shown, force: true))
    }

    @Test func forcedUpdateRendersWithNoPriorShownContent() {
        #expect(RenderGate.shouldRender(content(), shownAs: nil, force: true))
    }
}
