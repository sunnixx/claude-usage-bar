#if os(macOS)
import ClaudeUsageCore
import Foundation
import ServiceManagement

/// Wraps SMAppService, which throws for unregistered or unsigned bundles.
struct MacLoginItem: LoginItemControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClaudeUsageBar: login item change failed: \(error.localizedDescription)")
        }
    }
}
#endif
