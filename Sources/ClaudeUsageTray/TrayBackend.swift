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
    func update(_ content: TrayContent)
}
