# Windows and Linux Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the same usage readout on Windows and Linux as on macOS, from one Swift codebase, without weakening the macOS app or its tested core.

**Architecture:** Split the single macOS package into a portable `ClaudeUsageCore` (Foundation only), a per-platform token store, and a `TrayBackend` protocol with one implementation per OS. Everything verifiable — core logic, the new file-based token store, and compilation on all three platforms — lands and is proven green in CI *before* any unrunnable tray code is written.

**Tech Stack:** Swift 6, SwiftPM, AppKit (macOS), libayatana-appindicator + GTK3 via C interop (Linux), Win32 + GDI via WinSDK (Windows), Swift Testing, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-15-cross-platform-design.md`

## Global Constraints

- **Swift tools version 6.0**, strict concurrency ON. `platforms: [.macOS(.v14)]` (declares the macOS floor only; it does not restrict Linux or Windows).
- **The token is read-only on every platform.** No `SecItemAdd`/`SecItemUpdate`/`SecItemDelete`, and no write, create, or truncate call against `.credentials.json`, anywhere, ever. Claude Code owns that credential and rotates it; writing to it would break the user's CLI login.
- **The token is never logged, printed, written to disk, or placed in an error value.** `UsageError` cases stay payload-free. Its only egress is `https://api.anthropic.com/api/oauth/usage`.
- **No new runtime dependency on macOS.** The macOS build must not acquire GTK or anything else in service of the other platforms.
- **`ClaudeUsageCore` imports only `Foundation`.** No `Security`, no `AppKit`, no `WinSDK`, no GTK. This is what makes the core testable on all three platforms.
- **Swift Testing, not XCTest.** `import Testing`, `@Test`, `@Suite`, `#expect`, `#require`.
- **Statics that aren't `Sendable`** (e.g. `ISO8601DateFormatter`) need `nonisolated(unsafe)` under Swift 6 strict concurrency. This is already the pattern in `ISO8601Flexible.swift`.
- **Existing behaviour is preserved exactly.** The refresh policy, backoff, and the two recorded rulings — a confirmed sign-out drops the value permanently; a single auth failure does not — must not change.
- Run all tests with `swift test`. Every task ends green.

---

## File Structure

**Created:**
- `Sources/ClaudeUsageCore/TokenProviding.swift` — the token protocol, lookup/error types, and shared JSON parsing (moved out of `KeychainTokenStore.swift`)
- `Sources/ClaudeUsageTokens/KeychainTokenStore.swift` — macOS only (moved)
- `Sources/ClaudeUsageTokens/CredentialsFileTokenStore.swift` — Linux/Windows only
- `Sources/ClaudeUsageTray/TrayBackend.swift` — the protocol all backends implement
- `Sources/ClaudeUsageTray/AppKitTray.swift` — macOS backend (from `MenuBarController.swift`)
- `Sources/ClaudeUsageTray/AppIndicatorTray.swift` — Linux backend
- `Sources/ClaudeUsageTray/Win32Tray.swift` — Windows backend
- `Sources/ClaudeUsageTray/Win32Icon.swift` — GDI percentage-into-icon renderer
- `Sources/CAppIndicator/module.modulemap` — C interop shim, Linux only
- `Sources/ClaudeUsageBar/UsageDriver.swift` — platform-neutral poll loop
- `Sources/ClaudeUsageBar/LoginItem*.swift` — one per platform behind a protocol
- `Tests/ClaudeUsageCoreTests/CredentialsFileTokenStoreTests.swift`
- `.github/workflows/ci.yml`

**Modified:**
- `Package.swift` — four targets plus a conditional system library
- `Sources/ClaudeUsageCore/UsageClient.swift` — conditional `FoundationNetworking` import; `keychainUnavailable` → `tokenStoreUnavailable`
- `Sources/ClaudeUsageCore/UsageRefreshPolicy.swift` — same rename
- `Sources/ClaudeUsageCore/MenuModel.swift` — `MenuRow` carries fields; `StatusTitle` carries `percent`
- `Sources/ClaudeUsageBar/main.swift` — selects a backend per platform

**Deleted:** `Sources/ClaudeUsageBar/MenuBarController.swift`, `Sources/ClaudeUsageBar/AppDelegate.swift` (their content moves)

**Note on independence:** Tasks 1–5 produce complete, working software on their own — the macOS app refactored and hand-verified, with the core and token store proven green on all three platforms in CI. Tasks 6 and 7 are independent of each other; either can ship without the other, and either can be deferred.

---

### Task 1: Portable core

Strip every platform API out of `ClaudeUsageCore` so it compiles on Linux and Windows, and move the Keychain store into its own target.

**Files:**
- Create: `Sources/ClaudeUsageCore/TokenProviding.swift`
- Create: `Sources/ClaudeUsageTokens/KeychainTokenStore.swift`
- Delete: `Sources/ClaudeUsageCore/KeychainTokenStore.swift`
- Modify: `Sources/ClaudeUsageCore/UsageClient.swift`
- Modify: `Sources/ClaudeUsageCore/UsageRefreshPolicy.swift`
- Modify: `Sources/ClaudeUsageCore/MenuModel.swift`
- Modify: `Package.swift`
- Modify: `Tests/ClaudeUsageCoreTests/KeychainTokenStoreTests.swift`
- Modify: `Tests/ClaudeUsageCoreTests/UsageRefreshPolicyTests.swift`, `UsageClientTests.swift`, `MenuModelTests.swift` (rename only)

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `public enum TokenLookup: Equatable, Sendable { case token(String); case missing }`
  - `public protocol TokenProviding: Sendable { func accessToken() throws -> TokenLookup }`
  - `public enum TokenStoreError: Error, Equatable { case malformed; case unreadable; case platform(Int32) }`
  - `public enum CredentialsJSON { public static func parseToken(from data: Data) throws -> String }`
  - `UsageError.tokenStoreUnavailable` (was `.keychainUnavailable`)
  - `UsageState.tokenStoreUnavailable` (was `.keychainDenied`)
  - Target `ClaudeUsageTokens` exporting `KeychainTokenStore` on macOS.

- [ ] **Step 1: Write the failing test for shared JSON parsing**

Add to `Tests/ClaudeUsageCoreTests/KeychainTokenStoreTests.swift` (keep the existing tests; they will be re-pointed in Step 3):

```swift
@Test func parsesATokenFromCredentialsJSON() throws {
    let data = Data(#"{"claudeAiOauth":{"accessToken":"sk-test-123"}}"#.utf8)
    #expect(try CredentialsJSON.parseToken(from: data) == "sk-test-123")
}

@Test func rejectsAnEmptyToken() {
    let data = Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)
    #expect(throws: TokenStoreError.malformed) {
        try CredentialsJSON.parseToken(from: data)
    }
}

@Test func rejectsAMissingOAuthKey() {
    let data = Data(#"{"somethingElse":{}}"#.utf8)
    #expect(throws: TokenStoreError.malformed) {
        try CredentialsJSON.parseToken(from: data)
    }
}

@Test func rejectsNonJSON() {
    #expect(throws: TokenStoreError.malformed) {
        try CredentialsJSON.parseToken(from: Data("not json".utf8))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter parsesATokenFromCredentialsJSON`
Expected: FAIL — `cannot find 'CredentialsJSON' in scope`.

- [ ] **Step 3: Create the portable token protocol file**

Create `Sources/ClaudeUsageCore/TokenProviding.swift`:

```swift
import Foundation

public enum TokenLookup: Equatable, Sendable {
    case token(String)
    case missing
}

public protocol TokenProviding: Sendable {
    func accessToken() throws -> TokenLookup
}

/// Why a token store failed. Deliberately carries no token material.
public enum TokenStoreError: Error, Equatable {
    /// The payload was not the JSON shape we expect, or the token was empty.
    case malformed
    /// The store exists but could not be read (permissions, locked keychain).
    case unreadable
    /// A platform status code we don't model individually (OSStatus on macOS).
    case platform(Int32)
}

/// Claude Code stores the same JSON shape in the macOS Keychain and in
/// `.credentials.json` on Linux and Windows, so both stores share this parser.
public enum CredentialsJSON {
    public static func parseToken(from data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw TokenStoreError.malformed
        }
        return token
    }
}
```

- [ ] **Step 4: Move the Keychain store into its own target**

Create `Sources/ClaudeUsageTokens/KeychainTokenStore.swift` with the content below, then delete `Sources/ClaudeUsageCore/KeychainTokenStore.swift`. The whole file is wrapped in `#if os(macOS)` so the target compiles to nothing elsewhere.

```swift
#if os(macOS)
import ClaudeUsageCore
import Foundation
import Security

/// Reads the OAuth token Claude Code stores in the login Keychain.
///
/// This type never writes. Claude Code owns the token and rotates it; a second
/// process attempting a refresh could invalidate the running CLI session.
public struct KeychainTokenStore: TokenProviding {
    public static let defaultService = "Claude Code-credentials"

    private let service: String

    public init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    public func accessToken() throws -> TokenLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw TokenStoreError.malformed }
            return .token(try CredentialsJSON.parseToken(from: data))
        case errSecItemNotFound:
            // Claude Code is not signed in on this machine. An expected state,
            // not a failure.
            return .missing
        default:
            throw TokenStoreError.platform(status)
        }
    }
}
#endif
```

- [ ] **Step 5: Add the conditional networking import**

In `Sources/ClaudeUsageCore/UsageClient.swift`, replace the first line `import Foundation` with:

```swift
import Foundation

// URLSession lives in Foundation on Apple platforms and in FoundationNetworking
// on Linux and Windows.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

- [ ] **Step 6: Rename the Keychain-specific error case**

In `Sources/ClaudeUsageCore/UsageClient.swift`, in `enum UsageError`, replace the `keychainUnavailable` case and its comment with:

```swift
    /// The token store threw (denied prompt, locked keychain, unreadable or
    /// malformed credentials file) — distinct from `.noToken`, which means the
    /// lookup succeeded and found nothing. Treated as transient so a good value
    /// is never blanked.
    case tokenStoreUnavailable
```

Then in `fetchUsage()` change `throw UsageError.keychainUnavailable` to `throw UsageError.tokenStoreUnavailable`.

In `Sources/ClaudeUsageCore/UsageRefreshPolicy.swift`, rename `UsageState.keychainDenied` to `UsageState.tokenStoreUnavailable`, and update all four places the old names appear: the `displayPercent` switch, the `consecutiveAuthFailures` reset switch, and the `case .keychainUnavailable:` arm plus its `state = .keychainDenied` assignment.

In `Sources/ClaudeUsageCore/MenuModel.swift`, change `case .keychainDenied:` to `case .tokenStoreUnavailable:`.

- [ ] **Step 7: Make the message platform-appropriate**

The Keychain wording is meaningless on Linux and Windows, where the remedy is different. In `Sources/ClaudeUsageCore/MenuModel.swift`, replace the row for that case with:

```swift
        case .tokenStoreUnavailable:
            #if os(macOS)
            return [MenuRow(text: "Keychain access denied — allow in Keychain Access")]
            #else
            return [MenuRow(text: "Can't read Claude Code credentials")]
            #endif
```

- [ ] **Step 8: Update Package.swift**

Replace `Package.swift` entirely:

```swift
// swift-tools-version: 6.0
import PackageDescription

// The executable is macOS-only until the Linux and Windows tray backends land
// (Tasks 6 and 7). Until then, Linux and Windows CI builds and tests the
// portable targets, which is the point of the phasing: everything verifiable is
// proven green before any unrunnable code is written.
var targets: [Target] = [
    .target(name: "ClaudeUsageCore"),
    .target(name: "ClaudeUsageTokens", dependencies: ["ClaudeUsageCore"]),
    .testTarget(
        name: "ClaudeUsageCoreTests",
        dependencies: ["ClaudeUsageCore", "ClaudeUsageTokens"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "ClaudeUsageBar",
        dependencies: ["ClaudeUsageCore", "ClaudeUsageTokens"]
    )
)
#endif

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    targets: targets
)
```

- [ ] **Step 9: Re-point the test imports and renamed symbols**

In `Tests/ClaudeUsageCoreTests/KeychainTokenStoreTests.swift`, add `import ClaudeUsageTokens` beside the existing `import ClaudeUsageCore`, and wrap any test that references `KeychainTokenStore` itself in `#if os(macOS)` / `#endif`. The four `CredentialsJSON` tests from Step 1 stay outside that guard — they must run on all three platforms.

Across `UsageRefreshPolicyTests.swift`, `UsageClientTests.swift`, and `MenuModelTests.swift`, replace every `keychainUnavailable` with `tokenStoreUnavailable` and every `keychainDenied` with `tokenStoreUnavailable`. Rename the test `treatsAThrownKeychainErrorAsUnavailableNotNoToken` to `treatsAThrownTokenStoreErrorAsUnavailableNotNoToken`, and `reportsKeychainDeniedWhenNothingHasEverSucceeded` to `reportsTokenStoreUnavailableWhenNothingHasEverSucceeded`.

- [ ] **Step 10: Run the full suite**

Run: `swift test`
Expected: PASS, 73 tests (69 existing + 4 new).

- [ ] **Step 11: Confirm the core has no platform imports**

Run: `grep -rE '^import (Security|AppKit|WinSDK|Cocoa|ServiceManagement)' Sources/ClaudeUsageCore/`
Expected: no output. If anything prints, the core is not portable and the task is not done.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "refactor: make ClaudeUsageCore portable across platforms

Move KeychainTokenStore into its own macOS-only target, extract the shared
credentials-JSON parser into the core, and add the conditional
FoundationNetworking import URLSession needs off Apple platforms. Rename
keychainUnavailable to tokenStoreUnavailable now that it is not
Keychain-specific, with platform-appropriate menu text.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: MenuRow carries fields

Stop pre-padding menu text into a single string. Each platform's menu font differs, so the shells must lay out the fields themselves.

**Files:**
- Modify: `Sources/ClaudeUsageCore/MenuModel.swift`
- Modify: `Tests/ClaudeUsageCoreTests/MenuModelTests.swift`
- Modify: `Sources/ClaudeUsageBar/MenuBarController.swift`

**Deliberate deviation from the spec:** the spec's testing section calls the
monospace-line assertion "a macOS-only test". This plan instead puts
`monospaceLine` in `ClaudeUsageCore` — it is pure string logic with no AppKit in
it — so the alignment test runs on all three platforms. Strictly more coverage
for the exact bug that got through review last time. Nothing else changes: the
macOS renderer is still the only caller.

**Interfaces:**
- Consumes: `UsageState.tokenStoreUnavailable` from Task 1.
- Produces:
  - `public struct MenuRow: Equatable, Sendable` with `label: String`, `percent: Int?`, `bar: String?`, `reset: String?`, `isIndented: Bool`
  - `public struct StatusTitle: Equatable, Sendable` with `text: String`, `percent: Int?`, `isCritical: Bool`, `isStale: Bool`
  - `public static func MenuModel.monospaceLine(_ row: MenuRow) -> String` — the padded composition, in the core so it is testable on every platform

- [ ] **Step 1: Write the failing tests**

Replace the row-text assertions in `Tests/ClaudeUsageCoreTests/MenuModelTests.swift` with field assertions, and add a composition test:

```swift
@Test func buildsStructuredRowsForASnapshot() throws {
    let state = UsageState.loaded(Fixture.snapshot)
    let rows = MenuModel.rows(
        for: state, now: Fixture.now,
        calendar: .current, locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt
    )

    let session = try #require(rows.first)
    #expect(session.label == "Session (5h)")
    #expect(session.percent == 37)
    #expect(session.bar == "▓▓▓▓░░░░░░")
    #expect(session.isIndented == false)
}

@Test func marksScopedRowsAsIndented() throws {
    let rows = MenuModel.rows(
        for: .loaded(Fixture.snapshot), now: Fixture.now,
        calendar: .current, locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt
    )
    let scoped = try #require(rows.first { $0.isIndented })
    #expect(scoped.label == "Fable")
    #expect(scoped.percent == 10)
}

@Test func messageRowsCarryOnlyALabel() throws {
    let rows = MenuModel.rows(
        for: .noToken, now: Fixture.now,
        calendar: .current, locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt
    )
    let row = try #require(rows.first)
    #expect(row.label == "Not signed in to Claude Code")
    #expect(row.percent == nil)
    #expect(row.bar == nil)
    #expect(row.reset == nil)
}

@Test func composesAMonospaceLineWithAlignedColumns() {
    let plain = MenuRow(label: "This week", percent: 26,
                        bar: "▓▓▓░░░░░░░", reset: "resets Sat, Aug 8")
    let indented = MenuRow(label: "Fable", percent: 10,
                           bar: "▓░░░░░░░░░", reset: nil, isIndented: true)

    let a = MenuModel.monospaceLine(plain)
    let b = MenuModel.monospaceLine(indented)

    // The percent sign and the bar must sit at the same index on both rows —
    // the indent is absorbed by the label field, not prepended afterwards.
    #expect(a.distance(from: a.startIndex, to: a.firstIndex(of: "%")!) == 17)
    #expect(b.distance(from: b.startIndex, to: b.firstIndex(of: "%")!) == 17)
    #expect(a.distance(from: a.startIndex, to: a.firstIndex(of: "▓")!) == 20)
    #expect(b.distance(from: b.startIndex, to: b.firstIndex(of: "▓")!) == 20)
}

@Test func statusTitleCarriesTheRawPercent() {
    let title = MenuModel.statusTitle(for: .loaded(Fixture.snapshot))
    #expect(title.percent == 37)
    #expect(title.text == "◔ 37%")
}

@Test func statusTitlePercentIsNilWithoutAValue() {
    #expect(MenuModel.statusTitle(for: .noToken).percent == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MenuModelTests`
Expected: FAIL — `MenuRow` has no member `label`, `MenuModel` has no member `monospaceLine`.

- [ ] **Step 3: Restructure the types**

In `Sources/ClaudeUsageCore/MenuModel.swift`, replace the two structs at the top:

```swift
public struct StatusTitle: Equatable, Sendable {
    /// The formatted string macOS and Linux display beside the icon, e.g. "◔ 37%".
    public let text: String
    /// The raw number. Windows draws this into the icon bitmap itself, because
    /// the Win32 tray has no text field — so it must not have to parse `text`.
    public let percent: Int?
    public let isCritical: Bool
    public let isStale: Bool
}

public struct MenuRow: Equatable, Sendable {
    public let label: String
    public let percent: Int?
    public let bar: String?
    public let reset: String?
    public let isIndented: Bool

    public init(
        label: String,
        percent: Int? = nil,
        bar: String? = nil,
        reset: String? = nil,
        isIndented: Bool = false
    ) {
        self.label = label
        self.percent = percent
        self.bar = bar
        self.reset = reset
        self.isIndented = isIndented
    }
}
```

- [ ] **Step 4: Emit fields instead of strings**

Still in `MenuModel.swift`, change every message row from `MenuRow(text: "…")` to `MenuRow(label: "…")`, then replace `usageRows` and `line` with:

```swift
    private static func usageRows(
        _ snapshot: UsageSnapshot,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [MenuRow] {
        var rows: [MenuRow] = []

        if let session = snapshot.session {
            rows.append(row(label: "Session (5h)", window: session,
                            now: now, calendar: calendar, locale: locale))
        }
        if let week = snapshot.week {
            rows.append(row(label: "This week", window: week,
                            now: now, calendar: calendar, locale: locale))
        }
        for scope in snapshot.scopedWeekly {
            rows.append(row(
                label: scope.label,
                window: UsageWindow(percent: scope.percent, resetsAt: scope.resetsAt),
                now: now, calendar: calendar, locale: locale,
                indented: true
            ))
        }

        return rows
    }

    private static func row(
        label: String,
        window: UsageWindow,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        indented: Bool = false
    ) -> MenuRow {
        MenuRow(
            label: label,
            percent: window.percent,
            bar: Formatting.progressBar(percent: window.percent),
            reset: Formatting.resetDescription(
                window.resetsAt, now: now, calendar: calendar, locale: locale
            ),
            isIndented: indented
        )
    }

    /// Composes the padded, column-aligned line the macOS menu renders in a
    /// monospaced font. Lives here rather than in the AppKit layer so it stays
    /// testable — the earlier column-misalignment bug survived review precisely
    /// because the padding was correct in isolation while the rendered result
    /// was not.
    ///
    /// The indent prefix is composed *inside* the label field so that it is
    /// absorbed by the padding, rather than prepended afterwards and pushing
    /// the row out of alignment.
    public static func monospaceLine(_ row: MenuRow) -> String {
        let displayLabel = row.isIndented ? "└ \(row.label)" : row.label
        let paddedLabel = displayLabel.padding(
            toLength: max(labelWidth, displayLabel.count), withPad: " ", startingAt: 0
        )

        guard let percent = row.percent else { return paddedLabel.trimmingCharacters(in: .whitespaces) }

        let percentText = Formatting.percentText(percent)
        let paddedPercent = String(
            repeating: " ", count: max(0, percentWidth - percentText.count)
        ) + percentText

        var line = "\(paddedLabel)\(paddedPercent)"
        if let bar = row.bar { line += "  \(bar)" }
        if let reset = row.reset { line += "  \(reset)" }
        return line
    }
```

- [ ] **Step 5: Give StatusTitle the raw percent**

In `statusTitle(for:)`, add `percent: percent` to the `StatusTitle(...)` construction. `percent` is already bound on the first line of that function.

- [ ] **Step 6: Point the macOS renderer at the composer**

In `Sources/ClaudeUsageBar/MenuBarController.swift`, inside `renderMenu()`, replace the two uses of `row.text` with the composed line:

```swift
            let line = MenuModel.monospaceLine(row)
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: line,
                attributes: [.font: font]
            )
```

- [ ] **Step 7: Run the suite**

Run: `swift test`
Expected: PASS. The alignment test proves the macOS output is unchanged.

- [ ] **Step 8: Verify the macOS app still looks right**

```bash
./Scripts/build-app.sh
pkill -f ClaudeUsageBar; open dist/ClaudeUsageBar.app
```

Open the dropdown. The columns must line up exactly as in `docs/images/screenshot.png` — percent signs aligned across session, week, and the indented per-model rows.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: MenuRow carries fields instead of a padded string

Each platform's menu font differs, so layout belongs in the shells. The
monospace composition moves into MenuModel where it is testable on every
platform, and the tests now assert field values rather than character
positions — the class of test that would have caught the earlier column
misalignment instead of pinning it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The file-based token store

Read `.credentials.json` on Linux and Windows. Injected path, so it is fully testable — better coverage than the Keychain store can have, since no GUI prompt is involved.

**Files:**
- Create: `Sources/ClaudeUsageTokens/CredentialsFileTokenStore.swift`
- Create: `Tests/ClaudeUsageCoreTests/CredentialsFileTokenStoreTests.swift`

**Interfaces:**
- Consumes: `TokenProviding`, `TokenLookup`, `TokenStoreError`, `CredentialsJSON.parseToken(from:)` from Task 1.
- Produces:
  - `public struct CredentialsFileTokenStore: TokenProviding`
  - `public init(path: URL)` and `public init()`
  - `public static func defaultPath(environment:home:) -> URL`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeUsageCoreTests/CredentialsFileTokenStoreTests.swift`:

```swift
#if !os(macOS)
import ClaudeUsageCore
import ClaudeUsageTokens
import Foundation
import Testing

@Suite struct CredentialsFileTokenStoreTests {
    /// Writes `contents` to a unique temporary file and returns its URL.
    /// Test-only: the store itself never writes.
    private func tempFile(_ contents: String, function: String = #function) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cutb-\(abs(function.hashValue))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".credentials.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    @Test func readsTheAccessToken() throws {
        let file = try tempFile(#"{"claudeAiOauth":{"accessToken":"sk-abc"}}"#)
        let store = CredentialsFileTokenStore(path: file)
        #expect(try store.accessToken() == .token("sk-abc"))
    }

    @Test func reportsMissingWhenTheFileIsAbsent() throws {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).json")
        let store = CredentialsFileTokenStore(path: absent)
        // Not signed in is an expected state, not an error.
        #expect(try store.accessToken() == .missing)
    }

    @Test func throwsOnMalformedJSON() throws {
        let file = try tempFile("{ this is not json")
        let store = CredentialsFileTokenStore(path: file)
        #expect(throws: TokenStoreError.malformed) { try store.accessToken() }
    }

    @Test func throwsOnAnEmptyToken() throws {
        let file = try tempFile(#"{"claudeAiOauth":{"accessToken":""}}"#)
        let store = CredentialsFileTokenStore(path: file)
        #expect(throws: TokenStoreError.malformed) { try store.accessToken() }
    }

    @Test func throwsWhenTheOAuthKeyIsAbsent() throws {
        let file = try tempFile(#"{"other":{"accessToken":"sk-abc"}}"#)
        let store = CredentialsFileTokenStore(path: file)
        #expect(throws: TokenStoreError.malformed) { try store.accessToken() }
    }

    @Test func honoursClaudeConfigDir() {
        let path = CredentialsFileTokenStore.defaultPath(
            environment: ["CLAUDE_CONFIG_DIR": "/custom/dir"],
            home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/custom/dir/.credentials.json")
    }

    @Test func fallsBackToTheHomeClaudeDirectory() {
        let path = CredentialsFileTokenStore.defaultPath(
            environment: [:],
            home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/home/someone/.claude/.credentials.json")
    }

    @Test func ignoresAnEmptyClaudeConfigDir() {
        let path = CredentialsFileTokenStore.defaultPath(
            environment: ["CLAUDE_CONFIG_DIR": ""],
            home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/home/someone/.claude/.credentials.json")
    }
}
#endif
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CredentialsFileTokenStoreTests`
Expected on macOS: 0 tests run (the suite is `#if !os(macOS)`). This is correct — these tests are proven by CI on Linux and Windows in Task 4. Confirm the package still builds with `swift build`.

- [ ] **Step 3: Implement the store**

Create `Sources/ClaudeUsageTokens/CredentialsFileTokenStore.swift`:

```swift
#if !os(macOS)
import ClaudeUsageCore
import Foundation

/// Reads the OAuth token Claude Code writes to `.credentials.json` on Linux
/// (`~/.claude`, mode 0600) and Windows (`%USERPROFILE%\.claude`), or under
/// `$CLAUDE_CONFIG_DIR` when that is set.
///
/// This type never writes. Claude Code owns the credential and rotates it, and
/// unlike the macOS Keychain this is an ordinary file — a careless write would
/// corrupt it and break the user's CLI login. There is deliberately no code
/// path here that creates, truncates, or modifies the file.
public struct CredentialsFileTokenStore: TokenProviding {
    private let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init() {
        self.init(path: Self.defaultPath())
    }

    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        }
        return home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    public func accessToken() throws -> TokenLookup {
        guard FileManager.default.fileExists(atPath: path.path) else {
            // Claude Code is not signed in on this machine. An expected state,
            // not a failure.
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: path, options: [])
        } catch {
            // Present but unreadable — wrong owner, or mode stripped of read.
            throw TokenStoreError.unreadable
        }

        return .token(try CredentialsJSON.parseToken(from: data))
    }
}
#endif
```

- [ ] **Step 4: Verify the store contains no write path**

Run: `grep -nE 'write|createFile|removeItem|truncate' Sources/ClaudeUsageTokens/CredentialsFileTokenStore.swift`
Expected: no output. Any hit is a violation of the read-only constraint and must be removed.

- [ ] **Step 5: Confirm the package builds**

Run: `swift build && swift test`
Expected: PASS on macOS (the new file compiles to nothing there).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: read .credentials.json on Linux and Windows

Injected path, so the store is fully unit-testable — no GUI prompt, unlike
the Keychain. Honours CLAUDE_CONFIG_DIR. Read-only by construction: there is
no code path that creates, truncates, or modifies the file, because Claude
Code owns that credential and a bad write would break the user's login.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: CI matrix — the verification gate

Prove the core and the new token store on all three platforms. **This is the gate:** everything verifiable must be green here before any tray code is written.

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: the target layout from Task 1, the store from Task 3.
- Produces: a green three-platform CI run. No Swift symbols.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    name: ${{ matrix.os }}
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [macos-latest, ubuntu-latest, windows-latest]

    steps:
      - uses: actions/checkout@v4

      - name: Set up Swift
        uses: SwiftyLab/setup-swift@latest
        with:
          swift-version: "6.0"

      # libayatana-appindicator and GTK are needed from Task 6 onward. Installed
      # now so the workflow does not change when the Linux backend lands.
      - name: Install Linux tray dependencies
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y libayatana-appindicator3-dev libgtk-3-dev

      - name: Build
        run: swift build --build-tests

      - name: Test
        run: swift test
```

- [ ] **Step 2: Push and watch the run**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build and test on macOS, Linux, and Windows

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
gh run watch
```

- [ ] **Step 3: Confirm all three platforms are green**

Run: `gh run list --limit 1` then `gh run view --log-failed` if anything failed.
Expected: three green jobs.

If Linux or Windows fails, the failure is real information about portability — fix it before proceeding rather than skipping the platform. Likely causes, in order: a missing `FoundationNetworking` import; `Bundle.module` fixture loading; a path separator assumption on Windows.

- [ ] **Step 4: Confirm the new tests actually ran off-macOS**

Run: `gh run view --log | grep -c "CredentialsFileTokenStoreTests"`
Expected: non-zero on the Linux and Windows jobs. If zero, the `#if !os(macOS)` guard or the test target wiring is wrong and the store is untested — fix before proceeding.

- [ ] **Step 5: Add a CI badge and platform note to the README**

At the top of `README.md`, directly under the `# ClaudeUsageBar` heading, add:

```markdown
[![CI](https://github.com/sunnixx/claude-usage-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/sunnixx/claude-usage-bar/actions/workflows/ci.yml)
```

- [ ] **Step 6: Commit and push**

```bash
git add README.md
git commit -m "docs: add CI badge

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 5: TrayBackend protocol and the macOS backend

Put today's AppKit code behind the protocol the other two platforms will implement, and make the poll loop platform-neutral. macOS must behave identically afterwards.

**Files:**
- Create: `Sources/ClaudeUsageTray/TrayBackend.swift`
- Create: `Sources/ClaudeUsageTray/AppKitTray.swift`
- Create: `Sources/ClaudeUsageCore/LoginItemControlling.swift`
- Create: `Sources/ClaudeUsageBar/MacLoginItem.swift`
- Create: `Sources/ClaudeUsageBar/UsageDriver.swift`
- Delete: `Sources/ClaudeUsageBar/MenuBarController.swift`, `Sources/ClaudeUsageBar/AppDelegate.swift`, `Sources/ClaudeUsageBar/LoginItem.swift`
- Modify: `Sources/ClaudeUsageBar/main.swift`, `Package.swift`

**Interfaces:**
- Consumes: `StatusTitle`, `MenuRow`, `MenuModel.monospaceLine(_:)` from Task 2; `UsageRefreshPolicy`, `UsageClient` from Task 1.
- Produces:
  - `public struct TrayContent: Sendable` — `title: StatusTitle`, `rows: [MenuRow]`, `loginItemEnabled: Bool`
  - `public struct TrayHandlers: Sendable` — `refresh`, `toggleLoginItem`, `menuWillOpen`, each `@Sendable () -> Void`
  - `public protocol TrayBackend: AnyObject, Sendable` — `func run(handlers: TrayHandlers) -> Never`, `func update(_ content: TrayContent)`
  - `public protocol LoginItemControlling: Sendable` — `var isEnabled: Bool { get }`, `func setEnabled(_ enabled: Bool)`
  - `final class AppKitTray: TrayBackend`
  - `final class UsageDriver` — `init(tray:client:loginItem:)`, `func start()`, `func makeHandlers() -> TrayHandlers`

- [ ] **Step 1: Write the failing test**

The tray itself is not unit-testable, but the content the driver hands it is. Create `Tests/ClaudeUsageCoreTests/TrayContentTests.swift`:

```swift
import ClaudeUsageCore
import Foundation
import Testing

@Suite struct TrayContentTests {
    @Test func buildsContentFromStateAndLoginFlag() {
        let title = MenuModel.statusTitle(for: .loaded(Fixture.snapshot))
        let rows = MenuModel.rows(
            for: .loaded(Fixture.snapshot), now: Fixture.now,
            calendar: .current, locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt
        )
        let content = TrayContent(title: title, rows: rows, loginItemEnabled: true)

        #expect(content.title.percent == 37)
        #expect(content.loginItemEnabled)
        #expect(!content.rows.isEmpty)
    }
}
```

`TrayContent` must therefore live in `ClaudeUsageCore`, not `ClaudeUsageTray` — it is a value type with no platform dependency, and putting it in the core is what makes it testable everywhere.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TrayContentTests`
Expected: FAIL — `cannot find 'TrayContent' in scope`.

- [ ] **Step 3: Define the portable protocols**

Create `Sources/ClaudeUsageCore/LoginItemControlling.swift`:

```swift
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
    public let title: StatusTitle
    public let rows: [MenuRow]
    public let loginItemEnabled: Bool

    public init(title: StatusTitle, rows: [MenuRow], loginItemEnabled: Bool) {
        self.title = title
        self.rows = rows
        self.loginItemEnabled = loginItemEnabled
    }
}
```

- [ ] **Step 4: Define the tray protocol**

Create `Sources/ClaudeUsageTray/TrayBackend.swift`:

```swift
import ClaudeUsageCore
import Foundation

public struct TrayHandlers: Sendable {
    public let refresh: @Sendable () -> Void
    public let toggleLoginItem: @Sendable () -> Void
    public let menuWillOpen: @Sendable () -> Void

    public init(
        refresh: @escaping @Sendable () -> Void,
        toggleLoginItem: @escaping @Sendable () -> Void,
        menuWillOpen: @escaping @Sendable () -> Void
    ) {
        self.refresh = refresh
        self.toggleLoginItem = toggleLoginItem
        self.menuWillOpen = menuWillOpen
    }
}

/// One implementation per platform. Everything unverifiable on Windows and
/// Linux lives behind this protocol, so a broken backend can display badly but
/// cannot produce a wrong number — all the logic sits in the tested core.
public protocol TrayBackend: AnyObject, Sendable {
    /// Installs the handlers and takes over the calling thread with the
    /// platform's run loop. Never returns.
    func run(handlers: TrayHandlers) -> Never

    /// Callable from any thread — the polling task calls this directly. Each
    /// implementation is responsible for marshalling to its own UI thread.
    /// Content arriving before `run` must be buffered and applied on start.
    func update(_ content: TrayContent)
}
```

- [ ] **Step 5: Implement the macOS backend**

Create `Sources/ClaudeUsageTray/AppKitTray.swift`. This is today's `MenuBarController` behind the protocol; the rendering logic is unchanged.

```swift
#if os(macOS)
import AppKit
import ClaudeUsageCore

public final class AppKitTray: NSObject, TrayBackend, NSMenuDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var handlers: TrayHandlers?
    /// Guarded by `lock`; read on the main thread, written from the poll task.
    private var pending: TrayContent?
    private var shown: TrayContent?
    private let lock = NSLock()

    public override init() { super.init() }

    public func run(handlers: TrayHandlers) -> Never {
        self.handlers = handlers

        let app = NSApplication.shared
        // Menu bar only: no Dock icon, no app menu.
        app.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                accessibilityDescription: "Claude usage"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = image == nil ? .noImage : .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        drainPending()
        app.run()
        fatalError("NSApplication.run returned")
    }

    public func update(_ content: TrayContent) {
        lock.lock()
        pending = content
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.drainPending() }
    }

    // MARK: - Main thread only

    private func drainPending() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next else { return }
        // Skip the rebuild when nothing changed, so a poll landing while the
        // menu is open doesn't flicker or reset the current highlight.
        guard next != shown else { return }
        shown = next
        render(next)
    }

    private func render(_ content: TrayContent) {
        renderTitle(content.title)
        renderMenu(content)
    }

    private func renderTitle(_ title: StatusTitle) {
        guard let button = statusItem?.button else { return }
        let color: NSColor
        if title.isCritical {
            // A near-limit warning must not be softened, even while stale.
            color = .systemRed
        } else if title.isStale {
            color = .secondaryLabelColor
        } else {
            color = .labelColor
        }
        button.attributedTitle = NSAttributedString(
            string: " \(title.text)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
            ]
        )
    }

    private func renderMenu(_ content: TrayContent) {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for row in content.rows {
            let line = MenuModel.monospaceLine(row)
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: line, attributes: [.font: font])
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        launch.target = self
        launch.state = content.loginItemEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ))
    }

    @objc private func refreshNow() { handlers?.refresh() }
    @objc private func toggleLogin() { handlers?.toggleLoginItem() }

    public func menuWillOpen(_ menu: NSMenu) {
        handlers?.menuWillOpen()
    }
}
#endif
```

- [ ] **Step 6: Move the login item behind the protocol**

Create `Sources/ClaudeUsageBar/MacLoginItem.swift` and delete `Sources/ClaudeUsageBar/LoginItem.swift`:

```swift
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
```

- [ ] **Step 7: Write the platform-neutral driver**

Create `Sources/ClaudeUsageBar/UsageDriver.swift` and delete `Sources/ClaudeUsageBar/AppDelegate.swift`. The polling behaviour — the single in-flight guard, the backoff, the forced refresh — is carried over unchanged.

```swift
import ClaudeUsageCore
import ClaudeUsageTray
import Foundation

/// Owns the poll loop and the refresh policy. Knows nothing about any platform:
/// it talks to a `TrayBackend` and a `LoginItemControlling` and nothing else.
final class UsageDriver: @unchecked Sendable {
    private let tray: any TrayBackend
    private let client: any UsageFetching
    private let loginItem: any LoginItemControlling

    private let lock = NSLock()
    private var policy = UsageRefreshPolicy()
    private var isFetching = false

    init(tray: any TrayBackend, client: any UsageFetching, loginItem: any LoginItemControlling) {
        self.tray = tray
        self.client = client
        self.loginItem = loginItem
    }

    func makeHandlers() -> TrayHandlers {
        TrayHandlers(
            refresh: { [weak self] in self?.refreshNow() },
            toggleLoginItem: { [weak self] in
                guard let self else { return }
                self.loginItem.setEnabled(!self.loginItem.isEnabled)
                self.publish()
            },
            menuWillOpen: { [weak self] in self?.refreshNow() }
        )
    }

    func start() {
        publish()
        Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.currentInterval))
            }
        }
    }

    private var currentInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return policy.interval
    }

    /// Out-of-band refresh from "Refresh Now" or menu-open. Resets any backoff
    /// so a user-initiated retry isn't stuck on a backed-off interval.
    private func refreshNow() {
        lock.lock()
        policy.forceRefreshRequested()
        lock.unlock()
        Task.detached { [weak self] in await self?.refresh() }
    }

    /// At most one fetch is ever in flight, whether triggered by the poll loop,
    /// "Refresh Now", or opening the menu. If one is running, this is a no-op.
    private func refresh() async {
        lock.lock()
        if isFetching { lock.unlock(); return }
        isFetching = true
        lock.unlock()

        defer {
            lock.lock(); isFetching = false; lock.unlock()
        }

        do {
            let snapshot = try await client.fetchUsage()
            lock.lock(); policy.record(success: snapshot); lock.unlock()
        } catch let error as UsageError {
            lock.lock(); policy.record(failure: error); lock.unlock()
        } catch {
            lock.lock(); policy.record(failure: .transport); lock.unlock()
        }
        publish()
    }

    private func publish() {
        lock.lock()
        let state = policy.state
        lock.unlock()

        tray.update(TrayContent(
            title: MenuModel.statusTitle(for: state),
            rows: MenuModel.rows(
                for: state, now: Date(),
                calendar: .current, locale: .current, timeZone: .current
            ),
            loginItemEnabled: loginItem.isEnabled
        ))
    }
}
```

- [ ] **Step 8: Rewrite the entry point**

Replace `Sources/ClaudeUsageBar/main.swift`:

```swift
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
```

- [ ] **Step 9: Add the tray target to Package.swift**

In `Package.swift`, add the tray target and make the executable depend on it:

```swift
    .target(name: "ClaudeUsageTray", dependencies: ["ClaudeUsageCore"]),
```

and change the executable's dependencies to `["ClaudeUsageCore", "ClaudeUsageTokens", "ClaudeUsageTray"]`.

- [ ] **Step 10: Run the suite**

Run: `swift test`
Expected: PASS, including the new `TrayContentTests`.

- [ ] **Step 11: Hand-verify the macOS app**

```bash
./Scripts/build-app.sh
pkill -f ClaudeUsageBar; open dist/ClaudeUsageBar.app
```

All of these must hold, because this task moved every line of UI code:
1. A percentage appears in the menu bar within a few seconds.
2. The dropdown columns align, including the indented per-model row.
3. "Refresh Now" updates the "Updated HH:MM" line.
4. "Launch at Login" toggles and the checkmark persists when the menu is reopened.
5. Opening the menu repeatedly does not spawn duplicate network calls —
   check with `lsof -a -p $(pgrep -f ClaudeUsageBar) -i -nP`.
6. Quit works.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "refactor: put the macOS tray behind a TrayBackend protocol

The poll loop becomes platform-neutral and every AppKit call moves behind
one protocol, so the Linux and Windows backends — which cannot be run
before release — can only display badly, never produce a wrong number.
Behaviour on macOS is unchanged: same single in-flight guard, same backoff,
same no-op-rebuild check.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Linux backend (libayatana-appindicator)

**Independent of Task 7.** Expect to iterate: this code is written from documentation and cannot be run on the development machine. CI proves it compiles and links; nothing proves it renders.

**Files:**
- Create: `Sources/CAppIndicator/module.modulemap`, `Sources/CAppIndicator/shim.h`
- Create: `Sources/ClaudeUsageTray/AppIndicatorTray.swift`
- Create: `Sources/ClaudeUsageBar/LinuxLoginItem.swift`
- Create: `Scripts/build-linux.sh`, `Resources/claude-usage-bar.desktop`
- Modify: `Package.swift`, `Sources/ClaudeUsageBar/main.swift`, `README.md`

**Interfaces:**
- Consumes: `TrayBackend`, `TrayHandlers`, `TrayContent`, `LoginItemControlling` from Task 5; `CredentialsFileTokenStore` from Task 3.
- Produces: `final class AppIndicatorTray: TrayBackend`, `struct LinuxLoginItem: LoginItemControlling`.

- [ ] **Step 1: Create the C interop shim**

Create `Sources/CAppIndicator/shim.h`:

```c
#pragma once
#include <libayatana-appindicator/app-indicator.h>
#include <gtk/gtk.h>
```

Create `Sources/CAppIndicator/module.modulemap`:

```
module CAppIndicator [system] {
    header "shim.h"
    export *
}
```

- [ ] **Step 2: Declare the system library**

In `Package.swift`, inside the `#if os(Linux)` branch you are about to add, register the system library so pkg-config supplies the include and link flags:

```swift
#if os(Linux)
targets.append(
    .systemLibrary(
        name: "CAppIndicator",
        path: "Sources/CAppIndicator",
        pkgConfig: "ayatana-appindicator3-0.1",
        providers: [.apt(["libayatana-appindicator3-dev", "libgtk-3-dev"])]
    )
)
#endif
```

Change the tray target so it picks the shim up only on Linux:

```swift
    .target(
        name: "ClaudeUsageTray",
        dependencies: [
            "ClaudeUsageCore",
            .target(name: "CAppIndicator", condition: .when(platforms: [.linux])),
        ]
    ),
```

And extend the executable guard from `#if os(macOS)` to `#if os(macOS) || os(Linux)`.

- [ ] **Step 3: Implement the backend**

Create `Sources/ClaudeUsageTray/AppIndicatorTray.swift`:

```swift
#if os(Linux)
import CAppIndicator
import ClaudeUsageCore
import Foundation

/// Linux tray via libayatana-appindicator, which speaks StatusNotifierItem with
/// an XEmbed fallback — so KDE, XFCE, Cinnamon, MATE and Budgie work. Vanilla
/// GNOME needs the AppIndicator extension; that is true of every tray app and
/// is not this app's to fix.
///
/// GTK is not thread-safe. Every call into GTK below happens on the thread that
/// called `run`, and `update` reaches it only through `g_idle_add`.
public final class AppIndicatorTray: TrayBackend, @unchecked Sendable {
    private var indicator: UnsafeMutablePointer<AppIndicator>?
    private var handlers: TrayHandlers?

    private let lock = NSLock()
    private var pending: TrayContent?
    private var shown: TrayContent?

    public init() {}

    public func run(handlers: TrayHandlers) -> Never {
        self.handlers = handlers

        var argc: Int32 = 0
        gtk_init(&argc, nil)

        indicator = app_indicator_new(
            "claude-usage-bar",
            "utilities-system-monitor",
            APP_INDICATOR_CATEGORY_APPLICATION_STATUS
        )
        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
        app_indicator_set_title(indicator, "Claude usage")

        applyPending()
        gtk_main()
        fatalError("gtk_main returned")
    }

    public func update(_ content: TrayContent) {
        lock.lock()
        pending = content
        lock.unlock()

        // Hop to the GTK thread. The retained pointer is balanced by the
        // takeRetainedValue in the callback below.
        let box = Unmanaged.passRetained(self).toOpaque()
        g_idle_add({ raw in
            guard let raw else { return 0 }
            let tray = Unmanaged<AppIndicatorTray>.fromOpaque(raw).takeRetainedValue()
            tray.applyPending()
            return 0  // G_SOURCE_REMOVE — one-shot
        }, box)
    }

    // MARK: - GTK thread only

    private func applyPending() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next, next != shown else { return }
        shown = next
        render(next)
    }

    private func render(_ content: TrayContent) {
        // The label is the only place the percentage can appear; the icon is a
        // fixed themed glyph.
        app_indicator_set_label(indicator, content.title.text, "100%")

        let menu = gtk_menu_new()

        for row in content.rows {
            // Pango <tt> keeps the columns aligned in a proportional menu font.
            let markup = "<tt>\(escapeMarkup(MenuModel.monospaceLine(row)))</tt>"
            let item = gtk_menu_item_new()
            let label = gtk_label_new(nil)
            gtk_label_set_markup(OpaquePointer(label), markup)
            gtk_label_set_xalign(OpaquePointer(label), 0)
            gtk_container_add(OpaquePointer(item), label)
            gtk_widget_set_sensitive(item, 0)
            gtk_menu_shell_append(OpaquePointer(menu), item)
        }

        appendSeparator(to: menu)
        appendAction(to: menu, title: "Refresh Now") { [weak self] in
            self?.handlers?.refresh()
        }
        appendCheck(
            to: menu, title: "Launch at Login", checked: content.loginItemEnabled
        ) { [weak self] in
            self?.handlers?.toggleLoginItem()
        }
        appendSeparator(to: menu)
        appendAction(to: menu, title: "Quit") { gtk_main_quit() }

        gtk_widget_show_all(menu)
        app_indicator_set_menu(indicator, OpaquePointer(menu))
    }

    private func appendSeparator(to menu: UnsafeMutablePointer<GtkWidget>?) {
        let sep = gtk_separator_menu_item_new()
        gtk_menu_shell_append(OpaquePointer(menu), sep)
    }

    private func appendAction(
        to menu: UnsafeMutablePointer<GtkWidget>?,
        title: String,
        action: @escaping () -> Void
    ) {
        let item = gtk_menu_item_new_with_label(title)
        connectActivate(item, action)
        gtk_menu_shell_append(OpaquePointer(menu), item)
    }

    private func appendCheck(
        to menu: UnsafeMutablePointer<GtkWidget>?,
        title: String,
        checked: Bool,
        action: @escaping () -> Void
    ) {
        let item = gtk_check_menu_item_new_with_label(title)
        gtk_check_menu_item_set_active(OpaquePointer(item), checked ? 1 : 0)
        connectActivate(item, action)
        gtk_menu_shell_append(OpaquePointer(menu), item)
    }

    /// Bridges a Swift closure to a GTK signal. The box is freed by the
    /// destroy notify when the menu item goes away.
    private func connectActivate(
        _ item: UnsafeMutablePointer<GtkWidget>?,
        _ action: @escaping () -> Void
    ) {
        final class Box { let action: () -> Void; init(_ a: @escaping () -> Void) { action = a } }
        let box = Unmanaged.passRetained(Box(action)).toOpaque()

        g_signal_connect_data(
            OpaquePointer(item),
            "activate",
            unsafeBitCast(
                { (_: UnsafeMutableRawPointer?, data: UnsafeMutableRawPointer?) in
                    guard let data else { return }
                    Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().action()
                } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
                to: GCallback.self
            ),
            box,
            { data, _ in
                guard let data else { return }
                Unmanaged<Box>.fromOpaque(data).release()
            },
            GConnectFlags(rawValue: 0)
        )
    }

    /// Pango markup is XML; the reset strings are ASCII but the label comes
    /// from the API response, so escape rather than trust it.
    private func escapeMarkup(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
#endif
```

- [ ] **Step 4: Implement the Linux login item**

Create `Sources/ClaudeUsageBar/LinuxLoginItem.swift`:

```swift
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
```

- [ ] **Step 5: Select the Linux backend at startup**

In `Sources/ClaudeUsageBar/main.swift`, replace the `#else #error(...)` branch with:

```swift
#elseif os(Linux)
let tray: any TrayBackend = AppIndicatorTray()
let tokens: any TokenProviding = CredentialsFileTokenStore()
let loginItem: any LoginItemControlling = LinuxLoginItem()
#else
#error("No tray backend for this platform yet — see Task 7.")
#endif
```

- [ ] **Step 6: Add the packaging script**

Create `Resources/claude-usage-bar.desktop`:

```
[Desktop Entry]
Type=Application
Name=Claude Usage Bar
Comment=Claude subscription usage in the system tray
Exec=claude-usage-bar
Icon=utilities-system-monitor
Categories=Utility;
Terminal=false
```

Create `Scripts/build-linux.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
# Builds the Linux binary and stages a tarball in dist/.
# Requires: libayatana-appindicator3-dev libgtk-3-dev
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

STAGE="dist/claude-usage-bar-linux"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$(swift build -c release --show-bin-path)/ClaudeUsageBar" "$STAGE/claude-usage-bar"
cp Resources/claude-usage-bar.desktop "$STAGE/"

tar -czf dist/claude-usage-bar-linux.tar.gz -C dist claude-usage-bar-linux
echo "Built dist/claude-usage-bar-linux.tar.gz"
```

- [ ] **Step 7: Verify it compiles and links in CI**

```bash
git add -A
git commit -m "feat: Linux tray backend via libayatana-appindicator

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
gh run watch
```

Expected: the `ubuntu-latest` job is green, and it now builds the executable too.

If the C interop fails to compile, the likeliest causes in order are: `pkgConfig` name wrong for the installed version (check `pkg-config --list-all | grep -i indicator`); `OpaquePointer` versus `UnsafeMutablePointer<GtkWidget>` mismatches at the `gtk_*` boundaries; the `@convention(c)` closure not being convertible because it captures — it must not capture anything.

- [ ] **Step 8: Document the Linux build**

Add to `README.md` under Build:

```markdown
### Linux

    sudo apt install libayatana-appindicator3-dev libgtk-3-dev
    ./Scripts/build-linux.sh

Works on KDE, XFCE, Cinnamon, MATE and Budgie. **GNOME** hides tray icons
unless the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/)
is installed — that applies to every tray app, not just this one.

The token is read from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`),
read-only. Nothing here ever writes it.
```

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "docs: Linux build instructions

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 7: Windows backend (Win32 + GDI)

**Independent of Task 6.** The Windows tray has no text field, so the percentage is drawn into the icon bitmap. As with Task 6, CI proves it compiles; nothing proves it renders.

**Files:**
- Create: `Sources/ClaudeUsageTray/Win32Icon.swift`, `Sources/ClaudeUsageTray/Win32Tray.swift`
- Create: `Sources/ClaudeUsageBar/WindowsLoginItem.swift`
- Modify: `Package.swift`, `Sources/ClaudeUsageBar/main.swift`, `README.md`

**Interfaces:**
- Consumes: `TrayBackend`, `TrayHandlers`, `TrayContent`, `LoginItemControlling` from Task 5; `CredentialsFileTokenStore` from Task 3.
- Produces: `enum Win32Icon { static func make(percent: Int?, critical: Bool, stale: Bool) -> HICON? }`, `final class Win32Tray: TrayBackend`, `struct WindowsLoginItem: LoginItemControlling`.

- [ ] **Step 1: Render the percentage into an icon**

Create `Sources/ClaudeUsageTray/Win32Icon.swift`:

```swift
#if os(Windows)
import WinSDK

/// `Shell_NotifyIcon` gives you a 16x16 icon and a tooltip — there is no
/// equivalent of NSStatusItem's title, so Windows cannot show "37%" as text
/// beside an icon. It draws the number into the icon instead, which is what
/// every battery and CPU percentage tray app on Windows does.
///
/// The caller owns the returned HICON and MUST DestroyIcon it once replaced.
/// This runs once a minute; leaking one GDI handle per call would matter
/// within hours.
enum Win32Icon {
    static let size: Int32 = 32

    static func make(percent: Int?, critical: Bool, stale: Bool) -> HICON? {
        let screen = GetDC(nil)
        defer { _ = ReleaseDC(nil, screen) }
        guard let memDC = CreateCompatibleDC(screen) else { return nil }
        defer { _ = DeleteDC(memDC) }

        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = size
        info.bmiHeader.biHeight = -size          // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)

        var bits: UnsafeMutableRawPointer?
        guard let colour = CreateDIBSection(memDC, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0)
        else { return nil }
        defer { _ = DeleteObject(colour) }

        // A 1bpp mask is required by CreateIconIndirect. Left all-zero so every
        // pixel is opaque and the alpha in the colour bitmap does the work.
        guard let mask = CreateBitmap(size, size, 1, 1, nil) else { return nil }
        defer { _ = DeleteObject(mask) }

        let old = SelectObject(memDC, colour)
        defer { _ = SelectObject(memDC, old) }

        let text: String
        if let percent { text = String(percent) } else { text = "—" }

        let font = CreateFontW(
            /* height */ -20, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0,
            DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
            DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH) | DWORD(FF_DONTCARE),
            "Segoe UI".wide
        )
        defer { _ = DeleteObject(font) }
        let oldFont = SelectObject(memDC, font)
        defer { _ = SelectObject(memDC, oldFont) }

        SetBkMode(memDC, TRANSPARENT)
        // Critical wins over stale: a near-limit warning must not be softened.
        let colourRef: COLORREF = critical ? RGB(232, 74, 74)
            : (stale ? RGB(140, 140, 140) : RGB(255, 255, 255))
        SetTextColor(memDC, colourRef)

        var rect = RECT(left: 0, top: 0, right: size, bottom: size)
        _ = DrawTextW(
            memDC, text.wide, -1, &rect,
            UINT(DT_CENTER) | UINT(DT_VCENTER) | UINT(DT_SINGLELINE)
        )

        // DrawTextW leaves alpha at 0 on a 32bpp DIB, which renders the glyph
        // fully transparent. Force alpha opaque wherever a pixel was written.
        if let bits {
            let pixels = bits.assumingMemoryBound(to: UInt32.self)
            for i in 0..<Int(size * size) where pixels[i] & 0x00FF_FFFF != 0 {
                pixels[i] |= 0xFF00_0000
            }
        }

        var iconInfo = ICONINFO(
            fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: colour
        )
        return CreateIconIndirect(&iconInfo)
    }
}

extension String {
    /// UTF-16, NUL-terminated, for the -W Win32 entry points.
    var wide: [UInt16] { Array(utf16) + [0] }
}
#endif
```

- [ ] **Step 2: Implement the backend**

Create `Sources/ClaudeUsageTray/Win32Tray.swift`:

```swift
#if os(Windows)
import ClaudeUsageCore
import Foundation
import WinSDK

private let kTrayMessage = UINT(WM_APP + 1)
private let kUpdateMessage = UINT(WM_APP + 2)
private let kMenuBase: UINT = 1000
private let kMenuRefresh: UINT = 1
private let kMenuLogin: UINT = 2
private let kMenuQuit: UINT = 3

/// Windows tray via Shell_NotifyIcon on a message-only window.
///
/// Win32 UI objects belong to the thread that created them, so every call below
/// happens on the thread that called `run`; `update` reaches it by PostMessage.
public final class Win32Tray: TrayBackend, @unchecked Sendable {
    private var window: HWND?
    private var icon: HICON?
    private var handlers: TrayHandlers?

    private let lock = NSLock()
    private var pending: TrayContent?
    private var shown: TrayContent?

    public init() {}

    public func run(handlers: TrayHandlers) -> Never {
        self.handlers = handlers

        let instance = GetModuleHandleW(nil)
        let className = "ClaudeUsageBarWindow".wide

        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = { hwnd, msg, wparam, lparam in
            Win32Tray.dispatch(hwnd, msg, wparam, lparam)
        }
        wc.hInstance = instance
        className.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
        _ = RegisterClassExW(&wc)

        // HWND_MESSAGE: a message-only window, so nothing appears on screen.
        window = CreateWindowExW(
            0, className, className, 0, 0, 0, 0, 0,
            HWND_MESSAGE, nil, instance, nil
        )
        // Route WndProc callbacks back to this instance. Unretained: the
        // instance outlives the window, which lives for the process.
        SetWindowLongPtrW(
            window, GWLP_USERDATA,
            LONG_PTR(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        )

        var data = notifyData()
        data.uFlags = UINT(NIF_ICON) | UINT(NIF_MESSAGE) | UINT(NIF_TIP)
        data.uCallbackMessage = kTrayMessage
        _ = Shell_NotifyIconW(DWORD(NIM_ADD), &data)

        applyPending()

        var msg = MSG()
        while GetMessageW(&msg, nil, 0, 0) > 0 {
            TranslateMessage(&msg)
            DispatchMessageW(&msg)
        }
        cleanUp()
        exit(0)
    }

    public func update(_ content: TrayContent) {
        lock.lock()
        pending = content
        lock.unlock()
        // Hop to the UI thread; PostMessage is one of the few thread-safe
        // Win32 calls.
        if let window { _ = PostMessageW(window, kUpdateMessage, 0, 0) }
    }

    // MARK: - UI thread only

    private static func dispatch(
        _ hwnd: HWND?, _ msg: UINT, _ wparam: WPARAM, _ lparam: LPARAM
    ) -> LRESULT {
        let raw = UnsafeMutableRawPointer(
            bitPattern: Int(GetWindowLongPtrW(hwnd, GWLP_USERDATA))
        )
        guard let raw else { return DefWindowProcW(hwnd, msg, wparam, lparam) }
        let tray = Unmanaged<Win32Tray>.fromOpaque(raw).takeUnretainedValue()

        switch msg {
        case kUpdateMessage:
            tray.applyPending()
            return 0
        case kTrayMessage:
            let event = UINT(lparam & 0xFFFF)
            if event == UINT(WM_RBUTTONUP) || event == UINT(WM_LBUTTONUP) {
                tray.handlers?.menuWillOpen()
                tray.showMenu()
            }
            return 0
        case UINT(WM_COMMAND):
            tray.handleCommand(UINT(wparam & 0xFFFF))
            return 0
        case UINT(WM_DESTROY):
            PostQuitMessage(0)
            return 0
        default:
            return DefWindowProcW(hwnd, msg, wparam, lparam)
        }
    }

    private func handleCommand(_ id: UINT) {
        switch id {
        case kMenuBase + kMenuRefresh: handlers?.refresh()
        case kMenuBase + kMenuLogin: handlers?.toggleLoginItem()
        case kMenuBase + kMenuQuit: PostQuitMessage(0)
        default: break
        }
    }

    private func applyPending() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next, next != shown else { return }
        shown = next

        let fresh = Win32Icon.make(
            percent: next.title.percent,
            critical: next.title.isCritical,
            stale: next.title.isStale
        )
        var data = notifyData()
        data.uFlags = UINT(NIF_ICON) | UINT(NIF_TIP)
        data.hIcon = fresh
        withUnsafeMutableBytes(of: &data.szTip) { buffer in
            let tip = next.title.text.wide
            let dest = buffer.bindMemory(to: UInt16.self)
            for (i, unit) in tip.prefix(dest.count - 1).enumerated() { dest[i] = unit }
            dest[min(tip.count, dest.count - 1)] = 0
        }
        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)

        // Replace only after the shell has taken the new one, then free the old
        // handle — otherwise this leaks a GDI object every minute.
        if let icon { DestroyIcon(icon) }
        icon = fresh
    }

    private func showMenu() {
        lock.lock()
        let content = shown
        lock.unlock()
        guard let content, let window, let menu = CreatePopupMenu() else { return }
        defer { _ = DestroyMenu(menu) }

        for row in content.rows {
            let line = MenuModel.monospaceLine(row)
            _ = AppendMenuW(menu, UINT(MF_STRING) | UINT(MF_GRAYED), 0, line.wide)
        }
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        _ = AppendMenuW(
            menu, UINT(MF_STRING), UINT_PTR(kMenuBase + kMenuRefresh), "Refresh Now".wide
        )
        _ = AppendMenuW(
            menu,
            UINT(MF_STRING) | UINT(content.loginItemEnabled ? MF_CHECKED : MF_UNCHECKED),
            UINT_PTR(kMenuBase + kMenuLogin), "Launch at Login".wide
        )
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(kMenuBase + kMenuQuit), "Quit".wide)

        var point = POINT()
        GetCursorPos(&point)
        // Required or the menu will not dismiss when the user clicks elsewhere.
        SetForegroundWindow(window)
        _ = TrackPopupMenu(
            menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil
        )
        _ = PostMessageW(window, UINT(WM_NULL), 0, 0)
    }

    private func notifyData() -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = 1
        return data
    }

    private func cleanUp() {
        var data = notifyData()
        _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        if let icon { DestroyIcon(icon) }
    }
}
#endif
```

- [ ] **Step 3: Implement the Windows login item**

Create `Sources/ClaudeUsageBar/WindowsLoginItem.swift`:

```swift
#if os(Windows)
import ClaudeUsageCore
import Foundation
import WinSDK

/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run — per-user, so it needs
/// no elevation.
struct WindowsLoginItem: LoginItemControlling {
    private static let subKey = #"Software\Microsoft\Windows\CurrentVersion\Run"#
    private static let valueName = "ClaudeUsageBar"

    var isEnabled: Bool {
        var size: DWORD = 0
        let status = RegGetValueW(
            HKEY_CURRENT_USER, Self.subKey.wide, Self.valueName.wide,
            DWORD(RRF_RT_REG_SZ), nil, nil, &size
        )
        return status == ERROR_SUCCESS
    }

    func setEnabled(_ enabled: Bool) {
        var key: HKEY?
        guard RegOpenKeyExW(
            HKEY_CURRENT_USER, Self.subKey.wide, 0, DWORD(KEY_SET_VALUE), &key
        ) == ERROR_SUCCESS, let key else { return }
        defer { RegCloseKey(key) }

        if enabled {
            let exe = "\"\(exePath())\"".wide
            exe.withUnsafeBufferPointer { buffer in
                buffer.baseAddress?.withMemoryRebound(
                    to: BYTE.self, capacity: buffer.count * 2
                ) { bytes in
                    _ = RegSetValueExW(
                        key, Self.valueName.wide, 0, DWORD(REG_SZ),
                        bytes, DWORD(buffer.count * 2)
                    )
                }
            }
        } else {
            _ = RegDeleteValueW(key, Self.valueName.wide)
        }
    }

    private func exePath() -> String {
        var buffer = [UInt16](repeating: 0, count: Int(MAX_PATH))
        let length = GetModuleFileNameW(nil, &buffer, DWORD(MAX_PATH))
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }
}
#endif
```

- [ ] **Step 4: Select the Windows backend at startup**

In `Sources/ClaudeUsageBar/main.swift`, replace the trailing `#else #error(...)` with:

```swift
#elseif os(Windows)
let tray: any TrayBackend = Win32Tray()
let tokens: any TokenProviding = CredentialsFileTokenStore()
let loginItem: any LoginItemControlling = WindowsLoginItem()
#else
#error("Unsupported platform.")
#endif
```

In `Package.swift`, extend the executable guard to `#if os(macOS) || os(Linux) || os(Windows)` — at which point the guard is unconditional, so remove it and append the executable target directly.

- [ ] **Step 5: Verify it compiles and links in CI**

```bash
git add -A
git commit -m "feat: Windows tray backend via Shell_NotifyIcon

The Win32 tray has no text field, so the percentage is drawn into the icon
bitmap with GDI and the full title goes in the tooltip. Old HICONs are
destroyed on replacement — this runs once a minute and would otherwise leak
a GDI handle per poll.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
gh run watch
```

Expected: the `windows-latest` job is green.

If it fails to compile, the likeliest causes in order are: `WNDCLASSEXW.lpszClassName` dangling because the `withUnsafeBufferPointer` scope ended (hoist the class-name buffer to a stored property); `LONG_PTR`/`Int` conversion mismatches around `SetWindowLongPtrW`; constants such as `HWND_MESSAGE` or `RRF_RT_REG_SZ` needing an explicit numeric cast under Swift's WinSDK overlay.

- [ ] **Step 6: Record the one packaging item that is not delivered**

The spec's packaging table says "`.exe` with an embedded icon resource". SwiftPM
offers no hook to run the Windows resource compiler, so the executable keeps the
default file icon. This is cosmetic only — the *tray* icon is generated at
runtime by `Win32Icon`, which is what the user actually sees.

Add to `docs/superpowers/specs/2026-08-15-cross-platform-design.md` under the
packaging table:

```markdown
The Windows `.exe` keeps the default file icon: SwiftPM has no hook for the
resource compiler. The tray icon is generated at runtime, so this affects only
how the binary looks in Explorer.
```

- [ ] **Step 7: Document the Windows build**

Add to `README.md` under Build:

```markdown
### Windows

    swift build -c release

The tray shows the percentage drawn into the icon, because the Windows
notification area has no text field beside an icon — the full `◔ 37%` is in
the tooltip. Right-click the icon for the menu.

The token is read from `%USERPROFILE%\.claude\.credentials.json` (or
`%CLAUDE_CONFIG_DIR%`), read-only.
```

Also update the top-of-README description to say macOS, Windows, and Linux rather than macOS alone, and add a line under the screenshot noting it shows the macOS build.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "docs: Windows build instructions

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

## Verification boundary

Tasks 1–5 are verifiable and must be proven before merging: `swift test` green on all three platforms in CI, plus the macOS hand-verification in Task 5 Step 11.

Tasks 6 and 7 produce code that compiles and links in CI but that **nobody has run**. Hosted runners have no desktop shell. Expect a round of fixes from the first person with a Linux or Windows desktop. When reporting this work, say that plainly rather than describing those platforms as "supported" without qualification.
