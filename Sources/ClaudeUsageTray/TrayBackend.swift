import ClaudeUsageCore
import Foundation

public struct TrayHandlers: Sendable {
    public let refresh: @Sendable () -> Void
    public let toggleLoginItem: @Sendable () -> Void
    public let menuWillOpen: @Sendable () -> Void

    public init(
        refresh: @escaping @Sendable () -> Void,
        toggleLoginItem: @escaping @Sendable () -> Void,
        menuWillOpen: @escaping @Sendable () -> Void
    ) {
        self.refresh = refresh
        self.toggleLoginItem = toggleLoginItem
        self.menuWillOpen = menuWillOpen
    }
}

/// One implementation per platform. Everything unverifiable on Windows and
/// Linux lives behind this protocol, so a broken backend can display badly but
/// cannot produce a wrong number — all the logic sits in the tested core.
public protocol TrayBackend: AnyObject, Sendable {
    /// Installs the handlers and takes over the calling thread with the
    /// platform's run loop. Never returns.
    func run(handlers: TrayHandlers) -> Never

    /// Callable from any thread — the polling task calls this directly. Each
    /// implementation is responsible for marshalling to its own UI thread.
    /// Content arriving before `run` must be buffered and applied on start.
    ///
    /// `force`: bypasses whatever "content is unchanged, skip the redraw"
    /// optimisation the backend applies internally, even when `content`
    /// compares equal (`TrayContent.==`, i.e. same `states` and login flag)
    /// to what is currently shown. The driver sets this on a menu-open
    /// rebuild specifically: `TrayContent` equality can't see that the
    /// relative reset captions ("resets in 2h 14m") the backend is about to
    /// recompute from `Date()` may have moved on even though the underlying
    /// state hasn't — an unforced update would then wrongly suppress the
    /// redraw and leave a stale caption on screen. `force: false` is the
    /// common case (an ordinary poll result) and must still suppress a
    /// redundant redraw when nothing has changed, so a poll landing while
    /// the menu is open doesn't flicker or reset the current highlight; see
    /// `RenderGate`, which every backend uses to make this same decision.
    ///
    /// Contract the driver relies on: this call must not block, and must not
    /// call back into the driver (directly or via a dispatched closure that
    /// could run before `update` returns). The driver serializes its publish
    /// decision and this call as a single atomic step under its own lock —
    /// synchronous, in-line reentrancy from within `update` would deadlock
    /// against that lock, and blocking here would stall every other publish.
    func update(_ content: TrayContent, force: Bool)
}

/// The "should this redraw, or is it a no-op?" decision shared by all three
/// `TrayBackend`s, so it has one implementation and one test instead of
/// three copies that could silently drift from each other. Each backend
/// still owns its own `shown` storage (their threading/locking models
/// differ too much to share that part), but asks `RenderGate` to make the
/// actual call.
public enum RenderGate {
    /// `force` bypasses the equality check outright — see `TrayBackend.update`'s
    /// doc comment for why a forced update must redraw even when `content`
    /// compares equal to `shown`.
    public static func shouldRender(_ content: TrayContent, shownAs shown: TrayContent?, force: Bool) -> Bool {
        force || content != shown
    }
}
