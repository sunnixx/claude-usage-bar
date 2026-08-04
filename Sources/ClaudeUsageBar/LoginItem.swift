import Foundation
import ServiceManagement

/// Wraps SMAppService, which throws for unregistered or unsigned bundles.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state, or nil if macOS refused the change.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return enabled
        } catch {
            NSLog("ClaudeUsageBar: login item change failed: \(error.localizedDescription)")
            return nil
        }
    }
}
