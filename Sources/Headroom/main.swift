import HeadroomCore
import HeadroomTokens
import HeadroomTray
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

// `CodexTokenStore()` needs no platform guard: unlike the Anthropic token,
// which lives in the macOS Keychain, Codex's credential is always a file
// (`~/.codex/auth.json`, or `$CODEX_HOME`) on every platform.
let driver = UsageDriver(
    tray: tray,
    clients: [
        (.anthropic, UsageClient(tokens: tokens)),
        (.codex, CodexClient(tokens: CodexTokenStore())),
    ],
    loginItem: loginItem
)
driver.start()
tray.run(handlers: driver.makeHandlers())
