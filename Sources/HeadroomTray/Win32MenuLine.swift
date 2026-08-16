import HeadroomCore

/// Composes the Windows tray's menu line for one `MenuRow`.
///
/// Deliberately NOT behind `#if os(Windows)`: `Win32Tray` (which IS behind
/// that guard, since it links WinSDK) is invisible to `@testable import
/// HeadroomTray` on macOS/Linux CI, so the one piece of Windows display
/// logic that has ever drifted from the core (it used to silently drop
/// `row.bar` — see the review that added this test) would otherwise stay
/// forever untested on the two platforms that actually run its tests. Pulling
/// the pure composition step out into its own platform-independent type lets
/// `HeadroomTrayTests` cover it everywhere, while `Win32Tray.swift` still
/// calls it for the real thing.
///
/// Win32 menus use the system proportional font, so the padded monospace
/// layout `MenuModel.monospaceLine` builds for macOS/Linux would render
/// ragged here. Compose from the fields instead, in the same order the core
/// renders them (percent, bar, reset) so Windows shows the same information
/// as the other two platforms.
public enum Win32MenuLine {
    public static func compose(_ row: MenuRow) -> String {
        var parts: [String] = [row.isIndented ? "    \(row.label)" : row.label]
        if let percent = row.percent { parts.append("\(percent)%") }
        if let bar = row.bar { parts.append(bar) }
        if let reset = row.reset { parts.append(reset) }
        return parts.joined(separator: "   ")
    }
}
