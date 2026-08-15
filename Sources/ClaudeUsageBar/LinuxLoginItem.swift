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
                let exe = URL(fileURLWithPath: CommandLine.arguments[0])
                    .resolvingSymlinksInPath().path
                let entry = """
                    [Desktop Entry]
                    Type=Application
                    Name=Claude Usage Bar
                    Exec=\(exe)
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
