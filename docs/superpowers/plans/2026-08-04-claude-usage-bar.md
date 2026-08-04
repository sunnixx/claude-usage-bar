# ClaudeUsageBar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app that displays the current Claude subscription 5-hour usage percentage, read live from Anthropic using the OAuth token Claude Code already stores in the Keychain.

**Architecture:** A Swift package with two targets. `ClaudeUsageCore` is a pure library — Keychain reading, HTTP, JSON decoding, formatting, and the refresh state machine — with no AppKit dependency, so all of it is unit tested. `ClaudeUsageBar` is a thin AppKit executable that owns the `NSStatusItem` and translates core state into a title and menu. A shell script assembles the executable into an `LSUIElement` `.app` bundle.

**Tech Stack:** Swift 6.2, SwiftPM (no Xcode project), AppKit, Security.framework, ServiceManagement, Swift Testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-08-04-claude-usage-bar-design.md`

## Global Constraints

- Swift tools version 6.0; platform floor `.macOS(.v14)`.
- No third-party dependencies. Foundation, AppKit, Security, ServiceManagement only.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`) — **not** XCTest.
- All tests live in `Tests/ClaudeUsageCoreTests`. The executable target has no tests; its behaviour is verified by hand.
- `ClaudeUsageCore` must never `import AppKit`.
- API endpoint: `https://api.anthropic.com/api/oauth/usage`.
- Required request headers, exactly: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-usage-bar/1.0 (macOS)`.
- Keychain generic password service name, exactly: `Claude Code-credentials`. Token is at JSON path `claudeAiOauth.accessToken`.
- The app reads the OAuth token and never writes or refreshes it.
- Poll interval 60s base, backing off ×2 to a 300s ceiling, resetting to 60s on success.
- Critical (red) threshold: session percent ≥ 90.
- The app is silent. Do not add `UNUserNotificationCenter` or any notification code.
- Run `swift test` before every commit; every commit must have all tests passing.

---

## File Structure

```
Package.swift
Sources/ClaudeUsageCore/
  UsageSnapshot.swift        Value types + JSON decoding
  ISO8601Flexible.swift      Date parsing that tolerates 6-digit fractional seconds
  Formatting.swift           percent → title, progress bar, reset-time strings
  KeychainTokenStore.swift   Reads Claude Code's Keychain item
  UsageClient.swift          One HTTPS GET, maps errors
  UsageRefreshPolicy.swift   State machine: state + next interval
  MenuModel.swift            UsageState → menu rows + status title (pure)
Sources/ClaudeUsageBar/
  main.swift                 NSApplication bootstrap
  AppDelegate.swift          Owns controller + poll loop
  MenuBarController.swift    NSStatusItem + NSMenu (AppKit only)
  LoginItem.swift            SMAppService wrapper
Resources/Info.plist
Scripts/build-app.sh
Tests/ClaudeUsageCoreTests/
  Fixtures/full.json
  Fixtures/minimal.json
  Fixtures/no-limits.json
  Fixture.swift
  UsageSnapshotTests.swift
  FormattingTests.swift
  KeychainTokenStoreTests.swift
  UsageClientTests.swift
  UsageRefreshPolicyTests.swift
  MenuModelTests.swift
```

The split is by responsibility, not layer: everything that can be tested without a screen lives in `ClaudeUsageCore`, and `ClaudeUsageBar` holds only code that touches AppKit.

---

### Task 1: Package skeleton and usage decoding

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeUsageCore/ISO8601Flexible.swift`
- Create: `Sources/ClaudeUsageCore/UsageSnapshot.swift`
- Create: `Tests/ClaudeUsageCoreTests/Fixtures/full.json`
- Create: `Tests/ClaudeUsageCoreTests/Fixtures/minimal.json`
- Create: `Tests/ClaudeUsageCoreTests/Fixtures/no-limits.json`
- Create: `Tests/ClaudeUsageCoreTests/Fixture.swift`
- Test: `Tests/ClaudeUsageCoreTests/UsageSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ISO8601Flexible.date(from: String) -> Date?`
  - `ISO8601Flexible.stripFractionalSeconds(_ s: String) -> String`
  - `struct UsageWindow: Equatable, Sendable { let percent: Int; let resetsAt: Date? }`
  - `struct ScopedWindow: Equatable, Sendable { let label: String; let percent: Int; let resetsAt: Date? }`
  - `struct UsageSnapshot: Equatable, Sendable { let session: UsageWindow?; let week: UsageWindow?; let scopedWeekly: [ScopedWindow]; let fetchedAt: Date }`
  - `static func UsageSnapshot.decode(from: Data, fetchedAt: Date) throws -> UsageSnapshot`

**Why `ISO8601Flexible` exists:** the API returns `2026-08-04T09:00:00.782828+00:00` — six fractional-second digits. `ISO8601DateFormatter` with `.withFractionalSeconds` expects three and returns `nil` here. We strip the fractional component entirely and parse the rest. Sub-second precision is irrelevant for a reset time displayed to the minute.

- [ ] **Step 1: Create the package manifest**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeUsageCore"),
        .executableTarget(
            name: "ClaudeUsageBar",
            dependencies: ["ClaudeUsageCore"]
        ),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

Create a placeholder so the executable target compiles — `Sources/ClaudeUsageBar/main.swift`:

```swift
// Replaced in Task 6.
print("ClaudeUsageBar")
```

- [ ] **Step 2: Add the fixtures**

`Tests/ClaudeUsageCoreTests/Fixtures/full.json` — the real response, captured 2026-08-04:

```json
{
  "five_hour": { "utilization": 37.0, "resets_at": "2026-08-04T09:00:00.782828+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
  "seven_day": { "utilization": 26.0, "resets_at": "2026-08-08T07:00:00.782854+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "limits": [
    { "kind": "session", "group": "session", "percent": 37, "severity": "normal", "resets_at": "2026-08-04T09:00:00.782828+00:00", "scope": null, "is_active": true },
    { "kind": "weekly_all", "group": "weekly", "percent": 26, "severity": "normal", "resets_at": "2026-08-08T07:00:00.782854+00:00", "scope": null, "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly", "percent": 10, "severity": "normal", "resets_at": "2026-08-08T06:59:59.783316+00:00", "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null }, "is_active": false }
  ],
  "extra_usage": { "is_enabled": false, "monthly_limit": null, "utilization": null },
  "spend": { "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 }, "limit": null, "percent": 0, "enabled": false },
  "member_dashboard_available": false
}
```

`Tests/ClaudeUsageCoreTests/Fixtures/minimal.json` — a plan reporting no per-model scopes and no reset times:

```json
{
  "five_hour": null,
  "seven_day": null,
  "limits": [
    { "kind": "session", "group": "session", "percent": 4, "severity": "normal", "resets_at": null, "scope": null, "is_active": true },
    { "kind": "weekly_all", "group": "weekly", "percent": 0, "severity": "normal", "resets_at": null, "scope": null, "is_active": false }
  ]
}
```

`Tests/ClaudeUsageCoreTests/Fixtures/no-limits.json` — exercises the top-level fallback when `limits` is absent:

```json
{
  "five_hour": { "utilization": 88.4, "resets_at": "2026-08-04T09:00:00.782828+00:00" },
  "seven_day": { "utilization": 51.0, "resets_at": "2026-08-08T07:00:00.782854+00:00" }
}
```

`Tests/ClaudeUsageCoreTests/Fixture.swift`:

```swift
import Foundation
import Testing

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }
}
```

- [ ] **Step 3: Write the failing tests**

`Tests/ClaudeUsageCoreTests/UsageSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct ISO8601FlexibleTests {
    @Test func stripsSixDigitFractionalSeconds() {
        #expect(
            ISO8601Flexible.stripFractionalSeconds("2026-08-04T09:00:00.782828+00:00")
                == "2026-08-04T09:00:00+00:00"
        )
    }

    @Test func leavesTimestampsWithoutFractionsAlone() {
        #expect(
            ISO8601Flexible.stripFractionalSeconds("2026-08-04T09:00:00Z")
                == "2026-08-04T09:00:00Z"
        )
    }

    @Test func parsesFractionalTimestamp() throws {
        let parsed = try #require(ISO8601Flexible.date(from: "2026-08-04T09:00:00.782828+00:00"))
        let expected = try #require(ISO8601Flexible.date(from: "2026-08-04T09:00:00Z"))
        #expect(parsed == expected)
    }

    @Test func returnsNilForGarbage() {
        #expect(ISO8601Flexible.date(from: "not a date") == nil)
    }
}

@Suite struct UsageSnapshotTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_000_000)

    @Test func decodesFullResponse() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("full"), fetchedAt: fetchedAt)

        #expect(snapshot.session?.percent == 37)
        #expect(snapshot.week?.percent == 26)
        #expect(snapshot.session?.resetsAt == ISO8601Flexible.date(from: "2026-08-04T09:00:00Z"))
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func decodesPerModelScopes() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("full"), fetchedAt: fetchedAt)

        #expect(snapshot.scopedWeekly.count == 1)
        #expect(snapshot.scopedWeekly.first?.label == "Fable")
        #expect(snapshot.scopedWeekly.first?.percent == 10)
    }

    @Test func toleratesMissingScopesAndResetTimes() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("minimal"), fetchedAt: fetchedAt)

        #expect(snapshot.session?.percent == 4)
        #expect(snapshot.session?.resetsAt == nil)
        #expect(snapshot.week?.percent == 0)
        #expect(snapshot.scopedWeekly.isEmpty)
    }

    @Test func fallsBackToTopLevelWindowsWhenLimitsAbsent() throws {
        let snapshot = try UsageSnapshot.decode(from: Fixture.data("no-limits"), fetchedAt: fetchedAt)

        #expect(snapshot.session?.percent == 88)
        #expect(snapshot.week?.percent == 51)
        #expect(snapshot.scopedWeekly.isEmpty)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            try UsageSnapshot.decode(from: Data("{nope".utf8), fetchedAt: fetchedAt)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test`
Expected: compile failure — `cannot find 'ISO8601Flexible' in scope`, `cannot find 'UsageSnapshot' in scope`.

- [ ] **Step 5: Implement `ISO8601Flexible`**

`Sources/ClaudeUsageCore/ISO8601Flexible.swift`:

```swift
import Foundation

/// Parses the timestamps returned by the usage API.
///
/// Those timestamps carry six fractional-second digits
/// ("2026-08-04T09:00:00.782828+00:00"). `ISO8601DateFormatter` expects
/// exactly three and returns nil otherwise, so the fractional component is
/// removed before parsing. Sub-second precision does not matter for a reset
/// time shown to the minute.
public enum ISO8601Flexible {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func date(from string: String) -> Date? {
        formatter.date(from: stripFractionalSeconds(string))
    }

    public static func stripFractionalSeconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber {
            end = string.index(after: end)
        }
        return String(string[string.startIndex..<dot]) + String(string[end...])
    }
}
```

- [ ] **Step 6: Implement `UsageSnapshot`**

`Sources/ClaudeUsageCore/UsageSnapshot.swift`:

```swift
import Foundation

public struct UsageWindow: Equatable, Sendable {
    public let percent: Int
    public let resetsAt: Date?

    public init(percent: Int, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct ScopedWindow: Equatable, Sendable {
    public let label: String
    public let percent: Int
    public let resetsAt: Date?

    public init(label: String, percent: Int, resetsAt: Date?) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let session: UsageWindow?
    public let week: UsageWindow?
    public let scopedWeekly: [ScopedWindow]
    public let fetchedAt: Date

    public init(
        session: UsageWindow?,
        week: UsageWindow?,
        scopedWeekly: [ScopedWindow],
        fetchedAt: Date
    ) {
        self.session = session
        self.week = week
        self.scopedWeekly = scopedWeekly
        self.fetchedAt = fetchedAt
    }

    public static func decode(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return UsageSnapshot(payload: payload, fetchedAt: fetchedAt)
    }
}

extension UsageSnapshot {
    /// Mirrors the API response. Nearly every field is plan-dependent and may
    /// be absent or null, so everything here is optional.
    struct Payload: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }

        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    let display_name: String?
                }
                let model: Model?
            }

            let kind: String?
            let percent: Double?
            let resets_at: String?
            let scope: Scope?
        }

        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
    }

    init(payload: Payload, fetchedAt: Date) {
        let limits = payload.limits ?? []

        func window(kind: String, fallback: Payload.Window?) -> UsageWindow? {
            if let limit = limits.first(where: { $0.kind == kind }), let percent = limit.percent {
                return UsageWindow(
                    percent: Int(percent.rounded()),
                    resetsAt: limit.resets_at.flatMap(ISO8601Flexible.date(from:))
                )
            }
            guard let fallback, let utilization = fallback.utilization else { return nil }
            return UsageWindow(
                percent: Int(utilization.rounded()),
                resetsAt: fallback.resets_at.flatMap(ISO8601Flexible.date(from:))
            )
        }

        self.init(
            session: window(kind: "session", fallback: payload.five_hour),
            week: window(kind: "weekly_all", fallback: payload.seven_day),
            scopedWeekly: limits.compactMap { limit in
                guard limit.kind == "weekly_scoped",
                      let label = limit.scope?.model?.display_name,
                      let percent = limit.percent
                else { return nil }
                return ScopedWindow(
                    label: label,
                    percent: Int(percent.rounded()),
                    resetsAt: limit.resets_at.flatMap(ISO8601Flexible.date(from:))
                )
            },
            fetchedAt: fetchedAt
        )
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — 9 tests.

- [ ] **Step 8: Commit**

```bash
cd ~/Developer/claude-usage-bar
git add Package.swift Sources Tests
git commit -m "feat: decode usage API responses"
```

---

### Task 2: Formatting

**Files:**
- Create: `Sources/ClaudeUsageCore/Formatting.swift`
- Test: `Tests/ClaudeUsageCoreTests/FormattingTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `Formatting.percentText(_ percent: Int?) -> String`
  - `Formatting.isCritical(_ percent: Int?) -> Bool`
  - `Formatting.progressBar(percent: Int, width: Int = 10) -> String`
  - `Formatting.resetDescription(_ date: Date?, now: Date, calendar: Calendar, locale: Locale) -> String?`
  - `Formatting.clockTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String`

Every function takes its calendar, locale, and time zone explicitly. That is what makes these tests deterministic on any machine.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageCoreTests/FormattingTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct FormattingTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = locale
        return calendar
    }

    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601Flexible.date(from: iso))
    }

    // MARK: percentText

    @Test func formatsAPercentage() {
        #expect(Formatting.percentText(37) == "37%")
    }

    @Test func showsADashWhenThereIsNoValue() {
        #expect(Formatting.percentText(nil) == "—")
    }

    // MARK: isCritical

    @Test(arguments: [(89, false), (90, true), (100, true)])
    func flagsCriticalAtNinetyPercent(percent: Int, expected: Bool) {
        #expect(Formatting.isCritical(percent) == expected)
    }

    @Test func absentValueIsNotCritical() {
        #expect(Formatting.isCritical(nil) == false)
    }

    // MARK: progressBar

    @Test func drawsAProportionalBar() {
        #expect(Formatting.progressBar(percent: 37, width: 10) == "▓▓▓▓░░░░░░")
        #expect(Formatting.progressBar(percent: 0, width: 10) == "░░░░░░░░░░")
        #expect(Formatting.progressBar(percent: 100, width: 10) == "▓▓▓▓▓▓▓▓▓▓")
    }

    @Test func clampsOutOfRangePercentages() {
        #expect(Formatting.progressBar(percent: -5, width: 10) == "░░░░░░░░░░")
        #expect(Formatting.progressBar(percent: 140, width: 10) == "▓▓▓▓▓▓▓▓▓▓")
    }

    // MARK: resetDescription

    @Test func describesNearResetsRelatively() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let reset = try date("2026-08-04T09:00:00Z")

        #expect(
            Formatting.resetDescription(reset, now: now, calendar: calendar, locale: locale)
                == "resets in 1h 12m"
        )
    }

    @Test func omitsHoursWhenUnderAnHour() throws {
        let now = try date("2026-08-04T08:48:00Z")
        let reset = try date("2026-08-04T09:00:00Z")

        #expect(
            Formatting.resetDescription(reset, now: now, calendar: calendar, locale: locale)
                == "resets in 12m"
        )
    }

    @Test func collapsesSubMinuteResets() throws {
        let now = try date("2026-08-04T08:59:30Z")
        let reset = try date("2026-08-04T09:00:00Z")

        #expect(
            Formatting.resetDescription(reset, now: now, calendar: calendar, locale: locale)
                == "resets in under a minute"
        )
    }

    @Test func reportsElapsedResetsAsImminent() throws {
        let now = try date("2026-08-04T09:00:01Z")
        let reset = try date("2026-08-04T09:00:00Z")

        #expect(
            Formatting.resetDescription(reset, now: now, calendar: calendar, locale: locale)
                == "resetting now"
        )
    }

    @Test func switchesToAbsoluteAtTwentyFourHours() throws {
        let now = try date("2026-08-04T07:00:00Z")

        // 23h59m away — still relative.
        let near = try date("2026-08-05T06:59:00Z")
        #expect(
            Formatting.resetDescription(near, now: now, calendar: calendar, locale: locale)
                == "resets in 23h 59m"
        )

        // Exactly 24h away — absolute.
        let far = try date("2026-08-05T07:00:00Z")
        #expect(
            Formatting.resetDescription(far, now: now, calendar: calendar, locale: locale)
                == "resets Wed, Aug 5"
        )
    }

    @Test func hasNoDescriptionWithoutADate() throws {
        let now = try date("2026-08-04T07:00:00Z")
        #expect(Formatting.resetDescription(nil, now: now, calendar: calendar, locale: locale) == nil)
    }

    // MARK: clockTime

    @Test func formatsAClockTime() throws {
        let moment = try date("2026-08-04T12:04:00Z")
        #expect(Formatting.clockTime(moment, locale: locale, timeZone: utc) == "12:04")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile failure — `cannot find 'Formatting' in scope`.

- [ ] **Step 3: Implement `Formatting`**

`Sources/ClaudeUsageCore/Formatting.swift`:

```swift
import Foundation

public enum Formatting {
    public static let criticalThreshold = 90

    public static func percentText(_ percent: Int?) -> String {
        guard let percent else { return "—" }
        return "\(percent)%"
    }

    public static func isCritical(_ percent: Int?) -> Bool {
        guard let percent else { return false }
        return percent >= criticalThreshold
    }

    public static func progressBar(percent: Int, width: Int = 10) -> String {
        let clamped = min(max(percent, 0), 100)
        let filled = Int((Double(clamped) / 100.0 * Double(width)).rounded())
        return String(repeating: "▓", count: filled)
            + String(repeating: "░", count: width - filled)
    }

    public static func resetDescription(
        _ date: Date?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String? {
        guard let date else { return nil }

        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting now" }
        if seconds < 60 { return "resets in under a minute" }

        if seconds < 24 * 60 * 60 {
            let totalMinutes = Int(seconds / 60)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return hours == 0
                ? "resets in \(minutes)m"
                : "resets in \(hours)h \(minutes)m"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "EEE, MMM d"
        return "resets \(formatter.string(from: date))"
    }

    public static func clockTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

If `switchesToAbsoluteAtTwentyFourHours` fails on the weekday name, check the fixture arithmetic rather than loosening the assertion — 2026-08-05 is a Wednesday.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/claude-usage-bar
git add Sources/ClaudeUsageCore/Formatting.swift Tests/ClaudeUsageCoreTests/FormattingTests.swift
git commit -m "feat: format percentages, bars, and reset times"
```

---

### Task 3: Keychain token store

**Files:**
- Create: `Sources/ClaudeUsageCore/KeychainTokenStore.swift`
- Test: `Tests/ClaudeUsageCoreTests/KeychainTokenStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum TokenLookup: Equatable, Sendable { case token(String), missing }`
  - `protocol TokenProviding: Sendable { func accessToken() throws -> TokenLookup }`
  - `struct KeychainTokenStore: TokenProviding` with `init(service: String = "Claude Code-credentials")`
  - `static func KeychainTokenStore.parseToken(from data: Data) throws -> String`
  - `enum KeychainError: Error, Equatable { case malformed, status(OSStatus) }`

**Testing boundary:** `parseToken` is pure and fully tested. The `SecItemCopyMatching` call is not — mocking the Keychain costs more than it catches. It is verified by hand in Step 6.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageCoreTests/KeychainTokenStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct KeychainTokenStoreTests {
    @Test func extractsTheAccessToken() throws {
        let json = Data("""
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","expiresAt":1234567890}}
        """.utf8)

        #expect(try KeychainTokenStore.parseToken(from: json) == "sk-ant-oat01-abc")
    }

    @Test func rejectsJSONWithoutTheOAuthObject() {
        let json = Data(#"{"somethingElse":true}"#.utf8)

        #expect(throws: KeychainError.malformed) {
            try KeychainTokenStore.parseToken(from: json)
        }
    }

    @Test func rejectsAnEmptyToken() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)

        #expect(throws: KeychainError.malformed) {
            try KeychainTokenStore.parseToken(from: json)
        }
    }

    @Test func rejectsNonJSONData() {
        #expect(throws: KeychainError.malformed) {
            try KeychainTokenStore.parseToken(from: Data("not json".utf8))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile failure — `cannot find 'KeychainTokenStore' in scope`.

- [ ] **Step 3: Implement the store**

`Sources/ClaudeUsageCore/KeychainTokenStore.swift`:

```swift
import Foundation
import Security

public enum TokenLookup: Equatable, Sendable {
    case token(String)
    case missing
}

public protocol TokenProviding: Sendable {
    func accessToken() throws -> TokenLookup
}

public enum KeychainError: Error, Equatable {
    case malformed
    case status(OSStatus)
}

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
            guard let data = item as? Data else { throw KeychainError.malformed }
            return .token(try Self.parseToken(from: data))
        case errSecItemNotFound:
            // Claude Code is not signed in on this machine. An expected state,
            // not a failure.
            return .missing
        default:
            throw KeychainError.status(status)
        }
    }

    public static func parseToken(from data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw KeychainError.malformed
        }
        return token
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Verify against the real Keychain by hand**

Add a temporary scratch file `Sources/ClaudeUsageBar/main.swift` body:

```swift
import ClaudeUsageCore

let store = KeychainTokenStore()
switch try store.accessToken() {
case .token(let token):
    print("token found, \(token.count) characters, prefix \(token.prefix(12))")
case .missing:
    print("no token")
}
```

Run: `swift run ClaudeUsageBar`
Expected: `token found, … characters, prefix sk-ant-oat01`.

**Expect a Keychain prompt.** The item was created by the Claude Code CLI, so its access control list does not include this binary. macOS will ask for permission the first time — choose **Always Allow**. Note that this prompt reappears whenever the binary is rebuilt with a different signature; it disappears once the app is a stable, signed bundle (Task 6). Never print the whole token.

Restore `main.swift` to the placeholder before committing.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/claude-usage-bar
git add Sources/ClaudeUsageCore/KeychainTokenStore.swift Tests/ClaudeUsageCoreTests/KeychainTokenStoreTests.swift
git commit -m "feat: read Claude Code's OAuth token from the Keychain"
```

---

### Task 4: Usage client

**Files:**
- Create: `Sources/ClaudeUsageCore/UsageClient.swift`
- Test: `Tests/ClaudeUsageCoreTests/UsageClientTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot.decode(from:fetchedAt:)` (Task 1), `TokenProviding` / `TokenLookup` (Task 3).
- Produces:
  - `enum UsageError: Error, Equatable { case noToken, unauthorized, transport, badStatus(Int), decoding }`
  - `protocol UsageFetching: Sendable { func fetchUsage() async throws -> UsageSnapshot }`
  - `struct UsageClient: UsageFetching` with `init(tokens: any TokenProviding, now: @escaping @Sendable () -> Date = Date.init, transport: @escaping UsageClient.Transport = UsageClient.urlSessionTransport)`
  - `typealias UsageClient.Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`

The injected `transport` closure is the seam that makes this testable without a network or a URLProtocol subclass.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageCoreTests/UsageClientTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

private struct StubTokens: TokenProviding {
    let result: Result<TokenLookup, KeychainError>

    static let valid = StubTokens(result: .success(.token("sk-ant-oat01-test")))
    static let missing = StubTokens(result: .success(.missing))
    static let broken = StubTokens(result: .failure(.malformed))

    func accessToken() throws -> TokenLookup { try result.get() }
}

private func respond(_ status: Int, _ body: Data) -> UsageClient.Transport {
    { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

@Suite struct UsageClientTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_000_000)

    private func client(
        tokens: any TokenProviding = StubTokens.valid,
        transport: @escaping UsageClient.Transport
    ) -> UsageClient {
        UsageClient(tokens: tokens, now: { self.fetchedAt }, transport: transport)
    }

    @Test func decodesASuccessfulResponse() async throws {
        let body = try Fixture.data("full")
        let snapshot = try await client(transport: respond(200, body)).fetchUsage()

        #expect(snapshot.session?.percent == 37)
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func sendsTheRequiredHeaders() async throws {
        let body = try Fixture.data("full")
        let captured = Captured()

        let transport: UsageClient.Transport = { request in
            await captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }

        _ = try await client(transport: transport).fetchUsage()
        let request = try #require(await captured.request)

        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-usage-bar/1.0 (macOS)")
    }

    @Test func reportsAMissingToken() async throws {
        await #expect(throws: UsageError.noToken) {
            try await client(tokens: StubTokens.missing, transport: respond(200, Data())).fetchUsage()
        }
    }

    @Test func treatsAKeychainFailureAsNoToken() async throws {
        await #expect(throws: UsageError.noToken) {
            try await client(tokens: StubTokens.broken, transport: respond(200, Data())).fetchUsage()
        }
    }

    @Test(arguments: [401, 403])
    func reportsAnExpiredToken(status: Int) async throws {
        await #expect(throws: UsageError.unauthorized) {
            try await client(transport: respond(status, Data())).fetchUsage()
        }
    }

    @Test func reportsUnexpectedStatusCodes() async throws {
        await #expect(throws: UsageError.badStatus(503)) {
            try await client(transport: respond(503, Data())).fetchUsage()
        }
    }

    @Test func reportsTransportFailures() async throws {
        let transport: UsageClient.Transport = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await #expect(throws: UsageError.transport) {
            try await client(transport: transport).fetchUsage()
        }
    }

    @Test func reportsUndecodableBodies() async throws {
        await #expect(throws: UsageError.decoding) {
            try await client(transport: respond(200, Data("{nope".utf8))).fetchUsage()
        }
    }
}

private actor Captured {
    private(set) var request: URLRequest?
    func set(_ request: URLRequest) { self.request = request }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile failure — `cannot find 'UsageClient' in scope`.

- [ ] **Step 3: Implement `UsageClient`**

`Sources/ClaudeUsageCore/UsageClient.swift`:

```swift
import Foundation

public enum UsageError: Error, Equatable {
    case noToken
    case unauthorized
    case transport
    case badStatus(Int)
    case decoding
}

public protocol UsageFetching: Sendable {
    func fetchUsage() async throws -> UsageSnapshot
}

public struct UsageClient: UsageFetching {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let userAgent = "claude-usage-bar/1.0 (macOS)"

    public static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.transport }
        return (data, http)
    }

    private let tokens: any TokenProviding
    private let now: @Sendable () -> Date
    private let transport: Transport

    public init(
        tokens: any TokenProviding,
        now: @escaping @Sendable () -> Date = Date.init,
        transport: @escaping Transport = UsageClient.urlSessionTransport
    ) {
        self.tokens = tokens
        self.now = now
        self.transport = transport
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        guard case .token(let token) = ((try? tokens.accessToken()) ?? .missing) else {
            throw UsageError.noToken
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw UsageError.transport
        }

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw UsageError.unauthorized
        default:
            throw UsageError.badStatus(response.statusCode)
        }

        do {
            return try UsageSnapshot.decode(from: data, fetchedAt: now())
        } catch {
            throw UsageError.decoding
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/claude-usage-bar
git add Sources/ClaudeUsageCore/UsageClient.swift Tests/ClaudeUsageCoreTests/UsageClientTests.swift
git commit -m "feat: fetch usage from the OAuth usage endpoint"
```

---

### Task 5: Refresh policy

**Files:**
- Create: `Sources/ClaudeUsageCore/UsageRefreshPolicy.swift`
- Test: `Tests/ClaudeUsageCoreTests/UsageRefreshPolicyTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot` (Task 1), `UsageError` (Task 4).
- Produces:
  - `enum UsageState: Equatable, Sendable { case loading, loaded(UsageSnapshot), stale(UsageSnapshot, since: Date), noToken, unauthorized, unreachable }`
  - `struct UsageRefreshPolicy: Equatable, Sendable` with `init()`, `var state: UsageState { get }`, `var interval: TimeInterval { get }`, `mutating func record(success: UsageSnapshot)`, `mutating func record(failure: UsageError)`
  - `UsageRefreshPolicy.baseInterval` = 60, `.maxInterval` = 300

This is a pure value type with no timer, which is exactly why it can be tested without waiting for real time. Task 6 drives it from an async loop.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageCoreTests/UsageRefreshPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct UsageRefreshPolicyTests {
    private func snapshot(percent: Int, at seconds: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(
            session: UsageWindow(percent: percent, resetsAt: nil),
            week: UsageWindow(percent: 10, resetsAt: nil),
            scopedWeekly: [],
            fetchedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func startsLoadingAtTheBaseInterval() {
        let policy = UsageRefreshPolicy()

        #expect(policy.state == .loading)
        #expect(policy.interval == 60)
    }

    @Test func recordsASuccessfulFetch() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)

        policy.record(success: fetched)

        #expect(policy.state == .loaded(fetched))
        #expect(policy.interval == 60)
    }

    @Test func backsOffOnRepeatedFailures() {
        var policy = UsageRefreshPolicy()

        policy.record(failure: .transport)
        #expect(policy.interval == 120)

        policy.record(failure: .transport)
        #expect(policy.interval == 240)

        policy.record(failure: .transport)
        #expect(policy.interval == 300)

        policy.record(failure: .transport)
        #expect(policy.interval == 300)
    }

    @Test func resetsTheIntervalOnSuccess() {
        var policy = UsageRefreshPolicy()
        policy.record(failure: .transport)
        policy.record(failure: .transport)

        policy.record(success: snapshot(percent: 5, at: 500))

        #expect(policy.interval == 60)
    }

    @Test func keepsTheLastValueWhenTheNetworkFails() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)
        policy.record(success: fetched)

        policy.record(failure: .transport)

        #expect(policy.state == .stale(fetched, since: Date(timeIntervalSince1970: 100)))
    }

    @Test func reportsUnreachableWhenNothingHasEverSucceeded() {
        var policy = UsageRefreshPolicy()

        policy.record(failure: .transport)

        #expect(policy.state == .unreachable)
    }

    @Test func dropsTheValueWhenTheTokenIsGone() {
        var policy = UsageRefreshPolicy()
        policy.record(success: snapshot(percent: 37, at: 100))

        policy.record(failure: .noToken)

        #expect(policy.state == .noToken)
    }

    @Test func dropsTheValueWhenTheTokenExpires() {
        var policy = UsageRefreshPolicy()
        policy.record(success: snapshot(percent: 37, at: 100))

        policy.record(failure: .unauthorized)

        #expect(policy.state == .unauthorized)
    }

    @Test func treatsBadStatusLikeATransportFailure() {
        var policy = UsageRefreshPolicy()
        let fetched = snapshot(percent: 37, at: 100)
        policy.record(success: fetched)

        policy.record(failure: .badStatus(503))

        #expect(policy.state == .stale(fetched, since: Date(timeIntervalSince1970: 100)))
    }

    @Test func recoversFromAStaleState() {
        var policy = UsageRefreshPolicy()
        policy.record(success: snapshot(percent: 37, at: 100))
        policy.record(failure: .transport)

        let fresh = snapshot(percent: 41, at: 200)
        policy.record(success: fresh)

        #expect(policy.state == .loaded(fresh))
        #expect(policy.interval == 60)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile failure — `cannot find 'UsageRefreshPolicy' in scope`.

- [ ] **Step 3: Implement the policy**

`Sources/ClaudeUsageCore/UsageRefreshPolicy.swift`:

```swift
import Foundation

public enum UsageState: Equatable, Sendable {
    case loading
    case loaded(UsageSnapshot)
    case stale(UsageSnapshot, since: Date)
    case noToken
    case unauthorized
    case unreachable

    /// The percentage shown in the menu bar, if there is one.
    public var displayPercent: Int? {
        switch self {
        case .loaded(let snapshot), .stale(let snapshot, _):
            return snapshot.session?.percent
        case .loading, .noToken, .unauthorized, .unreachable:
            return nil
        }
    }
}

/// Decides what to display and when to poll again.
///
/// A pure value type — it holds no timer and reads no clock, so the app can
/// drive it from a real loop while the tests drive it instantly.
public struct UsageRefreshPolicy: Equatable, Sendable {
    public static let baseInterval: TimeInterval = 60
    public static let maxInterval: TimeInterval = 300

    public private(set) var state: UsageState = .loading
    public private(set) var interval: TimeInterval = UsageRefreshPolicy.baseInterval

    private var lastSnapshot: UsageSnapshot?

    public init() {}

    public mutating func record(success snapshot: UsageSnapshot) {
        lastSnapshot = snapshot
        state = .loaded(snapshot)
        interval = Self.baseInterval
    }

    public mutating func record(failure: UsageError) {
        interval = min(interval * 2, Self.maxInterval)

        switch failure {
        case .noToken:
            // Signing out invalidates the number entirely — don't keep showing it.
            state = .noToken
        case .unauthorized:
            state = .unauthorized
        case .transport, .badStatus, .decoding:
            if let lastSnapshot {
                state = .stale(lastSnapshot, since: lastSnapshot.fetchedAt)
            } else {
                state = .unreachable
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/claude-usage-bar
git add Sources/ClaudeUsageCore/UsageRefreshPolicy.swift Tests/ClaudeUsageCoreTests/UsageRefreshPolicyTests.swift
git commit -m "feat: add refresh policy with backoff and stale retention"
```

---

### Task 6: Menu model

**Files:**
- Create: `Sources/ClaudeUsageCore/MenuModel.swift`
- Test: `Tests/ClaudeUsageCoreTests/MenuModelTests.swift`

**Interfaces:**
- Consumes: `UsageState` (Task 5), `Formatting` (Task 2), `UsageSnapshot` (Task 1).
- Produces:
  - `struct StatusTitle: Equatable, Sendable { let text: String; let isCritical: Bool }`
  - `struct MenuRow: Equatable, Sendable { let text: String; let isIndented: Bool }`
  - `MenuModel.statusTitle(for: UsageState) -> StatusTitle`
  - `MenuModel.rows(for: UsageState, now: Date, calendar: Calendar, locale: Locale, timeZone: TimeZone) -> [MenuRow]`

Everything the two AppKit surfaces display is decided here, in testable code. Task 7's `MenuBarController` only renders what this returns.

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageCoreTests/MenuModelTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct MenuModelTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = locale
        return calendar
    }

    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601Flexible.date(from: iso))
    }

    private func loadedSnapshot() throws -> UsageSnapshot {
        UsageSnapshot(
            session: UsageWindow(percent: 37, resetsAt: try date("2026-08-04T09:00:00Z")),
            week: UsageWindow(percent: 26, resetsAt: try date("2026-08-08T07:00:00Z")),
            scopedWeekly: [ScopedWindow(label: "Fable", percent: 10, resetsAt: nil)],
            fetchedAt: try date("2026-08-04T07:48:00Z")
        )
    }

    private func rows(_ state: UsageState, now: Date) -> [String] {
        MenuModel.rows(for: state, now: now, calendar: calendar, locale: locale, timeZone: utc)
            .map(\.text)
    }

    // MARK: statusTitle

    @Test func showsThePercentageWhenLoaded() throws {
        let title = MenuModel.statusTitle(for: .loaded(try loadedSnapshot()))

        #expect(title.text == "37%")
        #expect(title.isCritical == false)
    }

    @Test func marksHighUsageAsCritical() throws {
        let snapshot = UsageSnapshot(
            session: UsageWindow(percent: 93, resetsAt: nil),
            week: nil,
            scopedWeekly: [],
            fetchedAt: try date("2026-08-04T07:48:00Z")
        )

        #expect(MenuModel.statusTitle(for: .loaded(snapshot)).isCritical == true)
    }

    @Test(arguments: [UsageState.loading, .noToken, .unauthorized, .unreachable])
    func showsADashWhenThereIsNoValue(state: UsageState) {
        let title = MenuModel.statusTitle(for: state)

        #expect(title.text == "—")
        #expect(title.isCritical == false)
    }

    @Test func keepsShowingTheLastValueWhenStale() throws {
        let snapshot = try loadedSnapshot()
        let title = MenuModel.statusTitle(for: .stale(snapshot, since: snapshot.fetchedAt))

        #expect(title.text == "37%")
    }

    // MARK: rows

    @Test func listsBothWindowsAndEachScope() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let text = rows(.loaded(try loadedSnapshot()), now: now)

        #expect(text.count == 4)
        #expect(text[0] == "Session (5h)   37%  ▓▓▓▓░░░░░░  resets in 1h 12m")
        #expect(text[1] == "This week      26%  ▓▓▓░░░░░░░  resets Sat, Aug 8")
        #expect(text[2] == "Fable          10%  ▓░░░░░░░░░")
        #expect(text[3] == "Updated 07:48")
    }

    @Test func indentsScopeRowsOnly() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let menuRows = MenuModel.rows(
            for: .loaded(try loadedSnapshot()),
            now: now, calendar: calendar, locale: locale, timeZone: utc
        )

        #expect(menuRows.map(\.isIndented) == [false, false, true, false])
    }

    @Test func omitsScopeRowsWhenThePlanHasNone() throws {
        let now = try date("2026-08-04T07:48:00Z")
        let snapshot = UsageSnapshot(
            session: UsageWindow(percent: 4, resetsAt: nil),
            week: UsageWindow(percent: 0, resetsAt: nil),
            scopedWeekly: [],
            fetchedAt: now
        )

        let text = rows(.loaded(snapshot), now: now)

        #expect(text.count == 3)
        #expect(text[0] == "Session (5h)    4%  ░░░░░░░░░░")
    }

    @Test func marksStaleDataWithTheLastSuccessTime() throws {
        let snapshot = try loadedSnapshot()
        let now = try date("2026-08-04T08:10:00Z")

        let text = rows(.stale(snapshot, since: snapshot.fetchedAt), now: now)

        #expect(text.last == "Offline — updated 07:48")
    }

    @Test func explainsEachFailureState() throws {
        let now = try date("2026-08-04T07:48:00Z")

        #expect(rows(.loading, now: now) == ["Loading…"])
        #expect(rows(.noToken, now: now) == ["Not signed in to Claude Code"])
        #expect(rows(.unauthorized, now: now) == ["Token expired — open Claude Code to refresh"])
        #expect(rows(.unreachable, now: now) == ["Can't reach Anthropic"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile failure — `cannot find 'MenuModel' in scope`.

- [ ] **Step 3: Implement `MenuModel`**

Note the column widths: the label is padded to 14 characters and the percentage right-aligned in 4, which is what makes the rows line up under a monospaced font. Those two numbers are exactly what the Task 6 row assertions encode — changing either breaks them.

`Sources/ClaudeUsageCore/MenuModel.swift`:

```swift
import Foundation

public struct StatusTitle: Equatable, Sendable {
    public let text: String
    public let isCritical: Bool
}

public struct MenuRow: Equatable, Sendable {
    public let text: String
    public let isIndented: Bool

    public init(text: String, isIndented: Bool = false) {
        self.text = text
        self.isIndented = isIndented
    }
}

/// Turns poller state into the exact strings both AppKit surfaces display.
public enum MenuModel {
    private static let labelWidth = 14
    private static let percentWidth = 4

    public static func statusTitle(for state: UsageState) -> StatusTitle {
        let percent = state.displayPercent
        return StatusTitle(
            text: Formatting.percentText(percent),
            isCritical: Formatting.isCritical(percent)
        )
    }

    public static func rows(
        for state: UsageState,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [MenuRow] {
        switch state {
        case .loading:
            return [MenuRow(text: "Loading…")]
        case .noToken:
            return [MenuRow(text: "Not signed in to Claude Code")]
        case .unauthorized:
            return [MenuRow(text: "Token expired — open Claude Code to refresh")]
        case .unreachable:
            return [MenuRow(text: "Can't reach Anthropic")]
        case .loaded(let snapshot):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(text: "Updated \(Formatting.clockTime(snapshot.fetchedAt, locale: locale, timeZone: timeZone))")]
        case .stale(let snapshot, let since):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(text: "Offline — updated \(Formatting.clockTime(since, locale: locale, timeZone: timeZone))")]
        }
    }

    private static func usageRows(
        _ snapshot: UsageSnapshot,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [MenuRow] {
        var rows: [MenuRow] = []

        if let session = snapshot.session {
            rows.append(MenuRow(text: line(
                label: "Session (5h)", window: session, now: now, calendar: calendar, locale: locale
            )))
        }
        if let week = snapshot.week {
            rows.append(MenuRow(text: line(
                label: "This week", window: week, now: now, calendar: calendar, locale: locale
            )))
        }
        for scope in snapshot.scopedWeekly {
            rows.append(MenuRow(
                text: line(
                    label: scope.label,
                    window: UsageWindow(percent: scope.percent, resetsAt: scope.resetsAt),
                    now: now, calendar: calendar, locale: locale
                ),
                isIndented: true
            ))
        }

        return rows
    }

    private static func line(
        label: String,
        window: UsageWindow,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let paddedLabel = label.padding(toLength: max(labelWidth, label.count), withPad: " ", startingAt: 0)
        let percent = String(
            repeating: " ",
            count: max(0, percentWidth - Formatting.percentText(window.percent).count)
        ) + Formatting.percentText(window.percent)
        let bar = Formatting.progressBar(percent: window.percent)

        var line = "\(paddedLabel)\(percent)  \(bar)"
        if let reset = Formatting.resetDescription(
            window.resetsAt, now: now, calendar: calendar, locale: locale
        ) {
            line += "  \(reset)"
        }
        return line
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

If a row assertion fails on spacing, fix the *test* string to match the widths above only after confirming the widths themselves are right — the columns must align, and the tests are the specification of that alignment.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/claude-usage-bar
git add Sources/ClaudeUsageCore/MenuModel.swift Tests/ClaudeUsageCoreTests/MenuModelTests.swift
git commit -m "feat: build menu rows and status title from usage state"
```

---

### Task 7: The app

**Files:**
- Create: `Sources/ClaudeUsageBar/AppDelegate.swift`
- Create: `Sources/ClaudeUsageBar/MenuBarController.swift`
- Create: `Sources/ClaudeUsageBar/LoginItem.swift`
- Create: `Resources/Info.plist`
- Create: `Scripts/build-app.sh`
- Create: `README.md`
- Modify: `Sources/ClaudeUsageBar/main.swift` (replace the placeholder)
- Modify: `.gitignore` (add `dist/`)

**Interfaces:**
- Consumes: `KeychainTokenStore()` (Task 3), `UsageClient(tokens:now:transport:)` and `UsageError` (Task 4), `UsageRefreshPolicy` / `UsageState` (Task 5), `MenuModel.statusTitle(for:)` and `MenuModel.rows(for:now:calendar:locale:timeZone:)` (Task 6).
- Produces: the `dist/ClaudeUsageBar.app` bundle.

This task has no automated tests. It is all AppKit and `SMAppService`; mocking either costs more than it would catch. Step 8 is a hand-verification checklist, and it is not optional.

- [ ] **Step 1: Write the login item wrapper**

`Sources/ClaudeUsageBar/LoginItem.swift`:

```swift
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
```

- [ ] **Step 2: Write the menu bar controller**

`Sources/ClaudeUsageBar/MenuBarController.swift`:

```swift
import AppKit
import ClaudeUsageCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Called when the user picks Refresh Now, or opens the menu.
    var onRefreshRequested: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var state: UsageState = .loading

    override init() {
        super.init()

        if let button = statusItem.button {
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
        statusItem.menu = menu

        render()
    }

    func update(state: UsageState) {
        self.state = state
        render()
    }

    // MARK: - Rendering

    private func render() {
        renderTitle()
        renderMenu()
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        let title = MenuModel.statusTitle(for: state)
        button.attributedTitle = NSAttributedString(
            string: " \(title.text)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: title.isCritical ? NSColor.systemRed : NSColor.labelColor,
            ]
        )
    }

    private func renderMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        for row in MenuModel.rows(
            for: state,
            now: Date(),
            calendar: .current,
            locale: .current,
            timeZone: .current
        ) {
            let item = NSMenuItem(title: row.text, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: row.isIndented ? "   └ \(row.text)" : row.text,
                attributes: [.font: font]
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: "Refresh Now",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        onRefreshRequested?()
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        renderMenu()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Rebuild first so relative reset times ("in 1h 12m") are current,
        // then ask for fresh data.
        renderMenu()
        onRefreshRequested?()
    }
}
```

- [ ] **Step 3: Write the app delegate**

`Sources/ClaudeUsageBar/AppDelegate.swift`:

```swift
import AppKit
import ClaudeUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private var policy = UsageRefreshPolicy()
    private let client = UsageClient(tokens: KeychainTokenStore())

    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        controller.onRefreshRequested = { [weak self] in self?.refreshNow() }
        self.controller = controller

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.policy.interval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
        refreshTask?.cancel()
    }

    /// Fires an out-of-band refresh without disturbing the polling loop.
    private func refreshNow() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.refreshTask = nil
        }
    }

    private func refresh() async {
        do {
            policy.record(success: try await client.fetchUsage())
        } catch let error as UsageError {
            policy.record(failure: error)
        } catch {
            policy.record(failure: .transport)
        }
        controller?.update(state: policy.state)
    }
}
```

- [ ] **Step 4: Replace `main.swift`**

`Sources/ClaudeUsageBar/main.swift`:

```swift
import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu bar only: no Dock icon, no menu bar app menu.
application.setActivationPolicy(.accessory)
application.run()
```

- [ ] **Step 5: Write the bundle Info.plist**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Usage</string>
    <key>CFBundleIdentifier</key>
    <string>com.klayytech.claude-usage-bar</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string></string>
</dict>
</plist>
```

- [ ] **Step 6: Write the build script**

`Scripts/build-app.sh`:

```bash
#!/bin/bash
# Builds dist/ClaudeUsageBar.app from the SwiftPM executable.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/dist/ClaudeUsageBar.app"

swift build -c release --package-path "$root"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/.build/release/ClaudeUsageBar" "$app/Contents/MacOS/ClaudeUsageBar"

# A stable ad-hoc signature keeps macOS from re-prompting for Keychain access
# on every rebuild, and SMAppService refuses to register unsigned bundles.
codesign --force --sign - --identifier com.klayytech.claude-usage-bar "$app"

echo "Built $app"
```

Make it executable:

```bash
chmod +x ~/Developer/claude-usage-bar/Scripts/build-app.sh
```

- [ ] **Step 7: Build and run**

```bash
cd ~/Developer/claude-usage-bar
swift test
./Scripts/build-app.sh
open dist/ClaudeUsageBar.app
```

Expected: no Dock icon appears; a gauge glyph and a percentage appear at the right end of the menu bar. A Keychain prompt appears the first time — choose **Always Allow**.

- [ ] **Step 8: Verify by hand**

Check each, and fix before committing:

- [ ] The menu bar shows the gauge glyph and a percentage (e.g. `37%`), not `—`.
- [ ] The percentage matches what `claude` reports for the 5-hour window — run `/usage` inside Claude Code and compare.
- [ ] No icon appears in the Dock and no app menu appears in the menu bar.
- [ ] Opening the menu shows the session row, the week row, any per-model rows indented under them, and an "Updated HH:MM" line — with the columns aligned.
- [ ] The glyph and text are legible in both light and dark mode. Toggle in System Settings → Appearance.
- [ ] "Refresh Now" updates the "Updated HH:MM" time.
- [ ] "Launch at Login" toggles and the checkmark persists after reopening the menu. If macOS refuses (check Console for "login item change failed"), move the app to `/Applications` and relaunch — `SMAppService` is unreliable for bundles outside it.
- [ ] Turn off Wi-Fi, wait ~60s, reopen the menu: the last percentage is still shown and the last row reads "Offline — updated HH:MM". Turn Wi-Fi back on and confirm it recovers.
- [ ] "Quit" terminates the app.

- [ ] **Step 9: Write the README**

`README.md`:

```markdown
# ClaudeUsageBar

A macOS menu bar readout of your Claude subscription usage — the 5-hour
session window at a glance, with the weekly window and per-model scopes in the
dropdown.

It reads the OAuth token Claude Code already stores in your login Keychain and
polls `https://api.anthropic.com/api/oauth/usage` once a minute. It never
writes or refreshes that token: Claude Code owns it. When the token expires,
the app says so and defers to Claude Code.

## Build

    ./Scripts/build-app.sh
    open dist/ClaudeUsageBar.app

Move `dist/ClaudeUsageBar.app` to `/Applications` before enabling "Launch at
Login" — `SMAppService` is unreliable for bundles elsewhere.

macOS will ask for Keychain access the first time, because the item was
created by the Claude Code CLI. Choose "Always Allow".

## Test

    swift test

Everything except the AppKit layer is covered. `MenuBarController`,
`LoginItem`, and the `SecItemCopyMatching` call are verified by hand — see
Task 7 of the implementation plan.

## Requirements

macOS 14+, Swift 6, Claude Code signed in.
```

- [ ] **Step 10: Commit**

```bash
cd ~/Developer/claude-usage-bar
printf 'dist/\n' >> .gitignore
git add Sources/ClaudeUsageBar Resources Scripts README.md .gitignore
git commit -m "feat: menu bar app with status item, dropdown, and login item"
```

---

## Verification

The whole plan is done when, from a clean checkout:

```bash
swift test && ./Scripts/build-app.sh && open dist/ClaudeUsageBar.app
```

produces a menu bar item showing a percentage that matches `/usage` in Claude Code, and every box in Task 7 Step 8 is ticked.
