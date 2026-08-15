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
    /// Contract the driver relies on: this call must not block, and must not
    /// call back into the driver (directly or via a dispatched closure that
    /// could run before `update` returns). The driver serializes its publish
    /// decision and this call as a single atomic step under its own lock —
    /// synchronous, in-line reentrancy from within `update` would deadlock
    /// against that lock, and blocking here would stall every other publish.
    func update(_ content: TrayContent)
}
