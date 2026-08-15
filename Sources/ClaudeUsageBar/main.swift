import ClaudeUsageCore
import ClaudeUsageTokens
import ClaudeUsageTray
import Foundation

#if os(macOS)
let tray: any TrayBackend = AppKitTray()
let tokens: any TokenProviding = KeychainTokenStore()
let loginItem: any LoginItemControlling = MacLoginItem()
#else
#error("No tray backend for this platform yet — see Tasks 6 and 7.")
#endif

let driver = UsageDriver(
    tray: tray,
    client: UsageClient(tokens: tokens),
    loginItem: loginItem
)
driver.start()
tray.run(handlers: driver.makeHandlers())
