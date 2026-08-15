import Foundation

/// Launch-at-login, which every platform implements differently:
/// `SMAppService` on macOS, a `Run` registry value on Windows, an XDG autostart
/// desktop entry on Linux. The driver never branches on platform.
public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    /// Best-effort. Implementations log and carry on if the OS refuses.
    func setEnabled(_ enabled: Bool)
}

/// Everything a tray needs to draw itself. A pure value so it can cross
/// threads freely and be asserted on in tests.
public struct TrayContent: Equatable, Sendable {
    public let title: StatusTitle
    public let rows: [MenuRow]
    public let loginItemEnabled: Bool

    public init(title: StatusTitle, rows: [MenuRow], loginItemEnabled: Bool) {
        self.title = title
        self.rows = rows
        self.loginItemEnabled = loginItemEnabled
    }
}
