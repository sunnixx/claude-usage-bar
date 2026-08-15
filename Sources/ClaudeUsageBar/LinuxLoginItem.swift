#if os(Linux)
import ClaudeUsageCore
import Foundation

/// XDG autostart: a desktop entry in ~/.config/autostart.
struct LinuxLoginItem: LoginItemControlling {
    private var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/autostart", isDirectory: true)
            .appendingPathComponent("claude-usage-bar.desktop")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                // NOT CommandLine.arguments[0]: that is whatever string invoked
                // the process, resolved (if relative) against the current
                // working directory — not against the executable's location.
                // Our own Resources/claude-usage-bar.desktop invokes the app as
                // a bare `Exec=claude-usage-bar` (PATH-resolved, no slash), so
                // arguments[0] would be "claude-usage-bar" with no directory
                // component; resolving that against whatever directory the
                // toggle happened to run from silently writes a path that does
                // not exist. /proc/self/exe is always the kernel's own record
                // of the running binary's absolute path, regardless of how it
                // was invoked.
                let exe = URL(fileURLWithPath: "/proc/self/exe")
                    .resolvingSymlinksInPath().path
                // Desktop Entry's Exec value is whitespace-tokenised, so an
                // unquoted path containing a space (e.g. an install under
                // "/opt/Claude Usage/") would be split into multiple argv
                // entries and fail to launch. Quote it.
                let entry = """
                    [Desktop Entry]
                    Type=Application
                    Name=Claude Usage Bar
                    Exec="\(exe)"
                    X-GNOME-Autostart-enabled=true
                    """
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(entry.utf8).write(to: path)
            } else if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        } catch {
            FileHandle.standardError.write(
                Data("ClaudeUsageBar: autostart change failed: \(error)\n".utf8)
            )
        }
    }
}
#endif
