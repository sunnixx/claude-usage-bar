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
    /// One entry per configured provider, in `Provider.allCases` order, so the
    /// menu bar and dropdown never reorder between updates. Every tray backend
    /// derives its title/icon and its dropdown rows from this directly, via
    /// `MenuModel`, at render time — nothing here is pre-rendered for a
    /// specific platform.
    public let states: [(Provider, UsageState)]
    public let loginItemEnabled: Bool

    public init(
        states: [(Provider, UsageState)],
        loginItemEnabled: Bool
    ) {
        self.states = states
        self.loginItemEnabled = loginItemEnabled
    }

    public static func == (lhs: TrayContent, rhs: TrayContent) -> Bool {
        lhs.loginItemEnabled == rhs.loginItemEnabled
            && lhs.states.count == rhs.states.count
            && zip(lhs.states, rhs.states).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}
