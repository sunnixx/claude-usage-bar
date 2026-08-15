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

let driver = UsageDriver(
    tray: tray,
    client: UsageClient(tokens: tokens),
    loginItem: loginItem
)
driver.start()
tray.run(handlers: driver.makeHandlers())
