import ClaudeUsageCore
import ClaudeUsageTokens
import ClaudeUsageTray
import Foundation

#if os(macOS)
let tray: any TrayBackend = AppKitTray()
let tokens: any TokenProviding = KeychainTokenStore()
let loginItem: any LoginItemControlling = MacLoginItem()
#elseif os(Linux)
let tray: any TrayBackend = AppIndicatorTray()
let tokens: any TokenProviding = CredentialsFileTokenStore()
let loginItem: any LoginItemControlling = LinuxLoginItem()
#elseif os(Windows)
let tray: any TrayBackend = Win32Tray()
let tokens: any TokenProviding = CredentialsFileTokenStore()
let loginItem: any LoginItemControlling = WindowsLoginItem()
#else
#error("Unsupported platform.")
#endif

// Task 7 adds Codex to this list; for now only Anthropic is wired.
let driver = UsageDriver(
    tray: tray,
    clients: [(.anthropic, UsageClient(tokens: tokens))],
    loginItem: loginItem
)
driver.start()
tray.run(handlers: driver.makeHandlers())
