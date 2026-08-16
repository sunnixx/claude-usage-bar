# ChatGPT Codex Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show ChatGPT Codex subscription usage beside Claude usage in the same app, with both providers' marks and percentages in the menu bar.

**Architecture:** Generalise the Anthropic-shaped core into a provider-agnostic one (`Provider`, a labelled `UsageWindow`, `ProviderSnapshot`), add a Codex token store and API client alongside the existing ones, run one refresh policy per provider so neither can blank the other, then render provider sections in the dropdown and two segments in the menu bar. The Claude path must stay behaviourally identical throughout — the 95 existing tests are the guard.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, AppKit (macOS), libayatana-appindicator (Linux), Win32 (Windows).

**Spec:** `docs/superpowers/specs/2026-08-15-codex-provider-design.md`

## Global Constraints

- **Swift tools version 6.0**, strict concurrency ON. `platforms: [.macOS(.v14)]`.
- **Both providers' tokens are READ-ONLY on every platform.** No `SecItemAdd`/`SecItemUpdate`/`SecItemDelete`; no write, create, truncate or delete against `~/.claude/.credentials.json` or `~/.codex/auth.json`. Both CLIs own and rotate their own tokens; a stray write breaks the user's login.
- **No credential material in logs, errors, or on disk.** `UsageError` cases stay payload-free.
- **The Codex response carries PII** — `email`, `user_id`, `account_id`. Decode only `plan_type` and the rate-limit windows. Never store, log, display, or put these in a fixture. **Committed fixtures use fabricated identifiers.**
- **The Claude readout does not change.** Same decoder logic, same window labels, same wording, same menu bar number (the five-hour session figure).
- `ClaudeUsageCore` imports only `Foundation`.
- **Swift Testing, NOT XCTest.** `import Testing`, `@Test`, `@Suite`, `#expect`, `#require`.
- Non-`Sendable` statics need `nonisolated(unsafe)` under Swift 6 strict concurrency.
- All three CI jobs must stay green. Do not weaken, delete or skip tests. No `continue-on-error`, no `|| true`.
- `.superpowers/` is git-ignored scratch — never commit from it.
- Baseline is **95 tests on macOS, 103 on Linux/Windows**.

---

## File Structure

**Created:**
- `Sources/ClaudeUsageCore/Provider.swift` — `Provider` enum
- `Sources/ClaudeUsageCore/ProviderSnapshot.swift` — labelled `UsageWindow`, `ProviderSnapshot`
- `Sources/ClaudeUsageCore/CodexSnapshot.swift` — Codex payload decoding + window labelling
- `Sources/ClaudeUsageCore/CodexClient.swift` — the Codex usage client
- `Sources/ClaudeUsageTokens/CodexTokenStore.swift` — reads `~/.codex/auth.json`, all platforms
- `Tests/ClaudeUsageCoreTests/Fixtures/codex-full.json`, `codex-free.json`, `codex-additional.json`
- `Tests/ClaudeUsageCoreTests/CodexSnapshotTests.swift`, `CodexTokenStoreTests.swift`, `ProviderSnapshotTests.swift`

**Modified:**
- `Sources/ClaudeUsageCore/UsageSnapshot.swift` — maps into `ProviderSnapshot`; `ScopedWindow` absorbed
- `Sources/ClaudeUsageCore/UsageRefreshPolicy.swift` — carries `ProviderSnapshot`
- `Sources/ClaudeUsageCore/MenuModel.swift` — provider sections, multi-segment title
- `Sources/ClaudeUsageCore/UsageClient.swift` — `TokenProviding` gains an account id; error wording
- `Sources/ClaudeUsageTray/UsageDriver.swift` — one policy per provider
- `Sources/ClaudeUsageTray/AppKitTray.swift`, `AppIndicatorTray.swift`, `Win32Tray.swift` — render segments
- `Sources/ClaudeUsageTray/ProviderMark.swift` (new, macOS) — drawn template marks

**Task order** is dependency-driven: the model generalises first (Task 1) so everything downstream has one shape to target; Codex decoding (2) and credentials (3) are independent of each other; the client (4) needs both; the policy split (5) and rendering (6, 7) come last because they consume everything above.

---

### Task 1: Generalise the model

Turn the Anthropic-shaped core into a provider-agnostic one, with the Claude path producing byte-identical output.

**Files:**
- Create: `Sources/ClaudeUsageCore/Provider.swift`, `Sources/ClaudeUsageCore/ProviderSnapshot.swift`
- Create: `Tests/ClaudeUsageCoreTests/ProviderSnapshotTests.swift`
- Modify: `Sources/ClaudeUsageCore/UsageSnapshot.swift`, `MenuModel.swift`, `UsageRefreshPolicy.swift`
- Modify: `Tests/ClaudeUsageCoreTests/UsageSnapshotTests.swift`, `MenuModelTests.swift`, `UsageRefreshPolicyTests.swift`, `TrayContentTests.swift`, `Tests/ClaudeUsageTrayTests/UsageDriverTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `public enum Provider: String, CaseIterable, Sendable { case anthropic, codex }` with `public var displayName: String` (`"Claude"`, `"Codex"`)
  - `public struct UsageWindow: Equatable, Sendable` — `label: String`, `percent: Int`, `resetsAt: Date?`, `isScoped: Bool`, memberwise `init(label:percent:resetsAt:isScoped:)` with `isScoped` defaulting to `false`
  - `public struct ProviderSnapshot: Equatable, Sendable` — `provider: Provider`, `planName: String?`, `windows: [UsageWindow]`, `fetchedAt: Date`; `public var primary: UsageWindow?` returning `windows.first`
  - `UsageSnapshot.decode(from:fetchedAt:) -> ProviderSnapshot` (return type changes)
  - `UsageRefreshPolicy` now carries `ProviderSnapshot` in `.loaded`/`.stale`
  - `ScopedWindow` is deleted

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeUsageCoreTests/ProviderSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct ProviderSnapshotTests {
    private func window(_ label: String, _ percent: Int, scoped: Bool = false) -> UsageWindow {
        UsageWindow(label: label, percent: percent, resetsAt: nil, isScoped: scoped)
    }

    @Test func primaryIsTheFirstWindow() {
        let snapshot = ProviderSnapshot(
            provider: .anthropic,
            planName: nil,
            windows: [window("Session (5h)", 37), window("This week", 26)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        // The menu bar reads `primary` — for Anthropic that must stay the
        // five-hour session figure, not the highest window.
        #expect(snapshot.primary?.label == "Session (5h)")
        #expect(snapshot.primary?.percent == 37)
    }

    @Test func primaryIsNilWithoutWindows() {
        let snapshot = ProviderSnapshot(
            provider: .codex, planName: "free", windows: [], fetchedAt: Date()
        )
        #expect(snapshot.primary == nil)
    }

    @Test func providersHaveDisplayNames() {
        #expect(Provider.anthropic.displayName == "Claude")
        #expect(Provider.codex.displayName == "Codex")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ProviderSnapshotTests`
Expected: FAIL — `cannot find 'ProviderSnapshot' in scope`.

- [ ] **Step 3: Create the provider type**

Create `Sources/ClaudeUsageCore/Provider.swift`:

```swift
import Foundation

/// A usage source. The order of the cases is the order the menu bar and the
/// dropdown present them, so it is deliberately fixed rather than sorted.
public enum Provider: String, CaseIterable, Sendable {
    case anthropic
    case codex

    public var displayName: String {
        switch self {
        case .anthropic: return "Claude"
        case .codex: return "Codex"
        }
    }
}
```

- [ ] **Step 4: Create the generalised snapshot**

Create `Sources/ClaudeUsageCore/ProviderSnapshot.swift`:

```swift
import Foundation

/// One rate-limit window. Both providers reduce to a list of these: Anthropic's
/// five-hour, weekly and per-model windows, and Codex's primary, secondary and
/// additional ones.
public struct UsageWindow: Equatable, Sendable {
    public let label: String
    public let percent: Int
    public let resetsAt: Date?
    /// Renders indented — Anthropic's per-model rows, Codex's additional limits.
    public let isScoped: Bool

    public init(label: String, percent: Int, resetsAt: Date?, isScoped: Bool = false) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.isScoped = isScoped
    }
}

public struct ProviderSnapshot: Equatable, Sendable {
    public let provider: Provider
    /// Codex reports a plan name; Anthropic's endpoint does not.
    public let planName: String?
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public init(
        provider: Provider,
        planName: String?,
        windows: [UsageWindow],
        fetchedAt: Date
    ) {
        self.provider = provider
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    /// The window the menu bar segment shows — the one that gates you soonest.
    /// Producers must emit it first: Anthropic's session, Codex's primary.
    public var primary: UsageWindow? { windows.first }
}
```

- [ ] **Step 5: Map the Anthropic decoder into it**

In `Sources/ClaudeUsageCore/UsageSnapshot.swift`, delete `ScopedWindow` and the old `UsageWindow`, delete the `UsageSnapshot` struct's stored properties and `init`, and keep `UsageSnapshot` as a namespace for the Anthropic decoding. Replace everything above `extension UsageSnapshot` with:

```swift
import Foundation

/// Decodes Anthropic's usage response. The decoding logic is unchanged — only
/// the type it produces is now the shared `ProviderSnapshot`.
public enum UsageSnapshot {
    public static func decode(from data: Data, fetchedAt: Date) throws -> ProviderSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return snapshot(from: payload, fetchedAt: fetchedAt)
    }
}
```

Then replace the `init(payload:fetchedAt:)` at the bottom with a static builder that emits windows **in order — session, week, then scopes** (the menu bar depends on session being first):

```swift
    static func snapshot(from payload: Payload, fetchedAt: Date) -> ProviderSnapshot {
        let limits = payload.limits ?? []

        func window(kind: String, label: String, fallback: Payload.Window?) -> UsageWindow? {
            if let limit = limits.first(where: { $0.kind == kind }), let percent = limit.percent {
                return UsageWindow(
                    label: label,
                    percent: Int(percent.rounded()),
                    resetsAt: limit.resets_at.flatMap(ISO8601Flexible.date(from:))
                )
            }
            guard let fallback, let utilization = fallback.utilization else { return nil }
            return UsageWindow(
                label: label,
                percent: Int(utilization.rounded()),
                resetsAt: fallback.resets_at.flatMap(ISO8601Flexible.date(from:))
            )
        }

        var windows: [UsageWindow] = []
        // Session first: `ProviderSnapshot.primary` is what the menu bar reads.
        if let session = window(kind: "session", label: "Session (5h)", fallback: payload.five_hour) {
            windows.append(session)
        }
        let weekly = window(kind: "weekly_all", label: "This week", fallback: payload.seven_day)
        if let weekly { windows.append(weekly) }

        for limit in limits {
            guard limit.kind == "weekly_scoped",
                  let label = limit.scope?.model?.display_name,
                  let percent = limit.percent
            else { continue }
            let resetsAt = limit.resets_at.flatMap(ISO8601Flexible.date(from:))
            // A scope that resets with the weekly window doesn't repeat the date.
            let repeatsWeekly = resetsAt != nil && resetsAt == weekly?.resetsAt
            windows.append(UsageWindow(
                label: label,
                percent: Int(percent.rounded()),
                resetsAt: repeatsWeekly ? nil : resetsAt,
                isScoped: true
            ))
        }

        return ProviderSnapshot(
            provider: .anthropic, planName: nil, windows: windows, fetchedAt: fetchedAt
        )
    }
```

Note the scope-reset de-duplication moves here from `MenuModel` — it is a property of the data, not the presentation, and `MenuModel` no longer knows which row is "the weekly one".

- [ ] **Step 6: Update MenuModel to consume windows**

In `Sources/ClaudeUsageCore/MenuModel.swift`, replace `usageRows(_:now:calendar:locale:)` and the `row(...)` helper with:

```swift
    private static func usageRows(
        _ snapshot: ProviderSnapshot,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [MenuRow] {
        snapshot.windows.map { window in
            MenuRow(
                label: window.label,
                percent: window.percent,
                bar: Formatting.progressBar(percent: window.percent),
                reset: Formatting.resetDescription(
                    window.resetsAt, now: now, calendar: calendar, locale: locale
                ),
                isIndented: window.isScoped
            )
        }
    }
```

Change `statusTitle(for:)` and `rows(for:...)` to take `UsageState` as before — their signatures do not change in this task.

- [ ] **Step 7: Update the policy's payload type**

In `Sources/ClaudeUsageCore/UsageRefreshPolicy.swift`, change every `UsageSnapshot` to `ProviderSnapshot`: the `.loaded`/`.stale` associated values, `lastSnapshot`, and `record(success:)`. The state-machine logic — the consecutive-auth-failure counting, the backoff, the two rulings — must not change by a single line **in this task**.

(Task 6 Step 5 makes one sanctioned change to this file: `.stale` gains a reason. Nothing else in the machine changes there either.)

- [ ] **Step 8: Update the existing tests to the new shape**

Across `UsageSnapshotTests.swift`, `MenuModelTests.swift`, `UsageRefreshPolicyTests.swift`, `TrayContentTests.swift` and `Tests/ClaudeUsageTrayTests/UsageDriverTests.swift`, replace snapshot construction:

```swift
// was
UsageSnapshot(
    session: UsageWindow(percent: 37, resetsAt: someDate),
    week: UsageWindow(percent: 26, resetsAt: otherDate),
    scopedWeekly: [ScopedWindow(label: "Fable", percent: 10, resetsAt: nil)],
    fetchedAt: fetched
)

// becomes
ProviderSnapshot(
    provider: .anthropic,
    planName: nil,
    windows: [
        UsageWindow(label: "Session (5h)", percent: 37, resetsAt: someDate),
        UsageWindow(label: "This week", percent: 26, resetsAt: otherDate),
        UsageWindow(label: "Fable", percent: 10, resetsAt: nil, isScoped: true),
    ],
    fetchedAt: fetched
)
```

`UsageSnapshotTests` asserts against the decoder, so update it to read `windows` by index/label rather than `session`/`week`/`scopedWeekly`. **Do not weaken any assertion** — every value asserted today must still be asserted. The scope-reset de-duplication tests move from `MenuModelTests` to `UsageSnapshotTests`, since the behaviour moved.

- [ ] **Step 9: Run the full suite**

Run: `swift test`
Expected: PASS. Count rises by 3 (the new `ProviderSnapshotTests`) to 98 on macOS.

- [ ] **Step 10: Prove the Claude output is unchanged**

Run: `./Scripts/build-app.sh && pkill -f ClaudeUsageBar; open dist/ClaudeUsageBar.app`
Open the dropdown. The rows must read exactly as before — same labels, same alignment, same reset text. This task is a refactor; any visible difference is a defect.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "refactor: generalise the core to a provider-agnostic model

UsageWindow gains a label and absorbs ScopedWindow; ProviderSnapshot replaces
the Anthropic-shaped UsageSnapshot as the type the policy and menu carry. The
Anthropic decoder keeps its logic and emits the same windows in the same order,
session first, because the menu bar reads ProviderSnapshot.primary.

Scope-reset de-duplication moves into the decoder, where it belongs: it is a
property of the data, not of the presentation.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Decode the Codex response

**Files:**
- Create: `Sources/ClaudeUsageCore/CodexSnapshot.swift`
- Create: `Tests/ClaudeUsageCoreTests/Fixtures/codex-full.json`, `codex-free.json`, `codex-additional.json`
- Create: `Tests/ClaudeUsageCoreTests/CodexSnapshotTests.swift`

**Interfaces:**
- Consumes: `Provider`, `UsageWindow`, `ProviderSnapshot` from Task 1.
- Produces:
  - `public enum CodexSnapshot { public static func decode(from data: Data, fetchedAt: Date) throws -> ProviderSnapshot }`
  - `static func windowLabel(seconds: Int) -> String` (internal, tested via `@testable`)

- [ ] **Step 1: Write the fixtures**

All identifiers are fabricated — the real response carries the user's e-mail, user id and account id, and none of that may enter the repository.

`Tests/ClaudeUsageCoreTests/Fixtures/codex-full.json`:

```json
{
  "user_id": "user-EXAMPLE0000000000000000",
  "account_id": "00000000-0000-0000-0000-000000000000",
  "email": "example@example.com",
  "plan_type": "pro",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 42,
      "limit_window_seconds": 18000,
      "reset_after_seconds": 7200,
      "reset_at": 1789416863
    },
    "secondary_window": {
      "used_percent": 63,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 200000,
      "reset_at": 1789600000
    }
  },
  "additional_rate_limits": null,
  "credits": { "has_credits": false, "unlimited": false, "balance": null }
}
```

`codex-free.json` — the shape observed live on a free plan, with a 30-day primary and no secondary:

```json
{
  "user_id": "user-EXAMPLE0000000000000000",
  "account_id": "00000000-0000-0000-0000-000000000000",
  "email": "example@example.com",
  "plan_type": "free",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 0,
      "limit_window_seconds": 2592000,
      "reset_after_seconds": 2592000,
      "reset_at": 1789416863
    },
    "secondary_window": null
  },
  "additional_rate_limits": null,
  "credits": { "has_credits": false, "unlimited": false, "balance": null }
}
```

`codex-additional.json` — primary plus a named additional limit:

```json
{
  "plan_type": "pro",
  "rate_limit": {
    "primary_window": {
      "used_percent": 10,
      "limit_window_seconds": 18000,
      "reset_at": 1789416863
    },
    "secondary_window": null
  },
  "additional_rate_limits": [
    {
      "limit_id": "code_review",
      "used_percent": 25,
      "limit_window_seconds": 604800,
      "reset_at": 1789600000
    }
  ]
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/ClaudeUsageCoreTests/CodexSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct CodexSnapshotTests {
    private let fetched = Date(timeIntervalSince1970: 1_789_000_000)

    @Test func decodesPrimaryAndSecondaryWindows() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-full"), fetchedAt: fetched)

        #expect(snapshot.provider == .codex)
        #expect(snapshot.planName == "pro")
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows[0].label == "5h")
        #expect(snapshot.windows[0].percent == 42)
        #expect(snapshot.windows[1].label == "This week")
        #expect(snapshot.windows[1].percent == 63)
    }

    @Test func primaryIsFirstSoTheMenuBarReadsIt() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-full"), fetchedAt: fetched)
        #expect(snapshot.primary?.percent == 42)
    }

    @Test func convertsEpochResetTimes() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-full"), fetchedAt: fetched)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_789_416_863))
    }

    @Test func handlesAFreePlanWithNoSecondaryWindow() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-free"), fetchedAt: fetched)

        #expect(snapshot.planName == "free")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].label == "30 days")
        #expect(snapshot.windows[0].percent == 0)
    }

    @Test func rendersAdditionalLimitsAsScopedRows() throws {
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-additional"), fetchedAt: fetched)

        let scoped = try #require(snapshot.windows.first { $0.isScoped })
        #expect(scoped.percent == 25)
        #expect(snapshot.windows.first?.isScoped == false)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            try CodexSnapshot.decode(from: Data("not json".utf8), fetchedAt: fetched)
        }
    }

    @Test func carriesNoPersonallyIdentifyingInformation() throws {
        // The response contains email, user_id and account_id. None of it may
        // survive decoding — the app has no use for it and must not hold it.
        let snapshot = try CodexSnapshot.decode(from: try Fixture.data("codex-full"), fetchedAt: fetched)
        let rendered = "\(snapshot)"

        #expect(!rendered.contains("@"))
        #expect(!rendered.lowercased().contains("user-"))
        #expect(!rendered.contains("00000000-0000"))
    }

    @Test(arguments: [
        (3600, "1h"), (18000, "5h"), (86399, "24h"),
        (604800, "This week"), (86400, "1 days"), (2592000, "30 days"),
    ])
    func labelsWindowsFromTheirDuration(seconds: Int, expected: String) {
        #expect(CodexSnapshot.windowLabel(seconds: seconds) == expected)
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter CodexSnapshotTests`
Expected: FAIL — `cannot find 'CodexSnapshot' in scope`.

- [ ] **Step 4: Implement the decoder**

Create `Sources/ClaudeUsageCore/CodexSnapshot.swift`:

```swift
import Foundation

/// Decodes ChatGPT Codex's usage response.
///
/// The response also carries `email`, `user_id` and `account_id`. Those fields
/// are deliberately absent from `Payload`: the app has no use for them, and not
/// decoding them is the simplest way to guarantee they are never stored,
/// logged, or displayed.
public enum CodexSnapshot {
    public static func decode(from data: Data, fetchedAt: Date) throws -> ProviderSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        var windows: [UsageWindow] = []
        // Primary first: `ProviderSnapshot.primary` is what the menu bar reads.
        if let window = payload.rate_limit?.primary_window.map(usageWindow) ?? nil {
            windows.append(window)
        }
        if let window = payload.rate_limit?.secondary_window.map(usageWindow) ?? nil {
            windows.append(window)
        }
        for additional in payload.additional_rate_limits ?? [] {
            guard let window = usageWindow(additional, isScoped: true) else { continue }
            windows.append(window)
        }

        return ProviderSnapshot(
            provider: .codex,
            planName: payload.plan_type,
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    private static func usageWindow(_ window: Payload.Window) -> UsageWindow? {
        usageWindow(window, isScoped: false)
    }

    private static func usageWindow(_ window: Payload.Window, isScoped: Bool) -> UsageWindow? {
        guard let percent = window.used_percent else { return nil }
        return UsageWindow(
            label: windowLabel(seconds: window.limit_window_seconds ?? 0),
            percent: Int(percent.rounded()),
            resetsAt: window.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            isScoped: isScoped
        )
    }

    /// Codex window durations are plan-dependent — a free plan reports one
    /// 30-day window, paid plans report a 5-hour and a weekly one — so labels
    /// are derived from the duration rather than hardcoded.
    static func windowLabel(seconds: Int) -> String {
        if seconds == 604_800 { return "This week" }
        if seconds >= 86_400, seconds % 86_400 == 0 { return "\(seconds / 86_400) days" }
        return "\(max(1, Int((Double(seconds) / 3600).rounded(.up))))h"
    }
}

extension CodexSnapshot {
    struct Payload: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int?
            let reset_at: Int?
        }

        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }

        let plan_type: String?
        let rate_limit: RateLimit?
        let additional_rate_limits: [Window]?
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --filter CodexSnapshotTests`
Expected: PASS.

Note `labelsWindowsFromTheirDuration` expects `86399 -> "24h"` (rounded up) and `86400 -> "1 days"`. If your rounding disagrees, fix the implementation — the test encodes the spec's table.

- [ ] **Step 6: Register the fixtures and run everything**

The fixtures live in the existing `Fixtures` directory, which `Package.swift` already copies — no manifest change needed.

Run: `swift test`
Expected: PASS, 106 on macOS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: decode ChatGPT Codex usage responses

Window labels are derived from limit_window_seconds because Codex window
durations are plan-dependent — a free plan reports a single 30-day window,
paid plans a 5-hour and a weekly one.

The payload's email, user_id and account_id are deliberately not decoded: the
app has no use for them, and omitting them from Payload is the simplest
guarantee they are never stored, logged or displayed. A test asserts none of
it survives decoding, and every committed fixture uses fabricated identifiers.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Read Codex credentials

**Files:**
- Create: `Sources/ClaudeUsageTokens/CodexTokenStore.swift`
- Create: `Tests/ClaudeUsageCoreTests/CodexTokenStoreTests.swift`
- Modify: `Sources/ClaudeUsageCore/TokenProviding.swift`

**Interfaces:**
- Consumes: `TokenProviding`, `TokenLookup`, `TokenStoreError` (existing).
- Produces:
  - `public struct CodexCredentials: Equatable, Sendable { public let accessToken: String; public let accountId: String? }`
  - `public enum CodexTokenLookup: Equatable, Sendable { case credentials(CodexCredentials); case missing }`
  - `public protocol CodexTokenProviding: Sendable { func credentials() throws -> CodexTokenLookup }`
  - `public struct CodexTokenStore: CodexTokenProviding` with `init(path: URL)`, `init()`, `static func defaultPath(environment:home:) -> URL`

Codex needs an account id alongside the token, which the existing `TokenProviding` cannot express — hence a sibling protocol rather than a change to the Claude one.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeUsageCoreTests/CodexTokenStoreTests.swift`:

```swift
import ClaudeUsageCore
import ClaudeUsageTokens
import Foundation
import Testing

@Suite struct CodexTokenStoreTests {
    private func tempFile(_ contents: String, function: String = #function) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(abs(function.hashValue))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("auth.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private let valid = """
        {"auth_mode":"chatgpt","tokens":{"access_token":"sk-codex-abc",\
        "account_id":"00000000-0000-0000-0000-000000000000","refresh_token":"r"}}
        """

    @Test func readsTheAccessTokenAndAccountId() throws {
        let store = CodexTokenStore(path: try tempFile(valid))
        let lookup = try store.credentials()

        guard case .credentials(let creds) = lookup else {
            Issue.record("expected credentials, got \(lookup)")
            return
        }
        #expect(creds.accessToken == "sk-codex-abc")
        #expect(creds.accountId == "00000000-0000-0000-0000-000000000000")
    }

    @Test func reportsMissingWhenTheFileIsAbsent() throws {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-codex-\(UUID().uuidString).json")
        #expect(try CodexTokenStore(path: absent).credentials() == .missing)
    }

    @Test func toleratesAMissingAccountId() throws {
        let store = CodexTokenStore(
            path: try tempFile(#"{"tokens":{"access_token":"sk-codex-abc"}}"#)
        )
        guard case .credentials(let creds) = try store.credentials() else {
            Issue.record("expected credentials")
            return
        }
        #expect(creds.accountId == nil)
    }

    @Test func throwsOnMalformedJSON() throws {
        let store = CodexTokenStore(path: try tempFile("{ not json"))
        #expect(throws: TokenStoreError.malformed) { try store.credentials() }
    }

    @Test func throwsWhenTheAccessTokenIsEmpty() throws {
        let store = CodexTokenStore(path: try tempFile(#"{"tokens":{"access_token":""}}"#))
        #expect(throws: TokenStoreError.malformed) { try store.credentials() }
    }

    @Test func honoursCodexHome() {
        let path = CodexTokenStore.defaultPath(
            environment: ["CODEX_HOME": "/custom/codex"],
            home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/custom/codex/auth.json")
    }

    @Test func fallsBackToTheHomeCodexDirectory() {
        let path = CodexTokenStore.defaultPath(
            environment: [:], home: URL(fileURLWithPath: "/home/someone")
        )
        #expect(path.path == "/home/someone/.codex/auth.json")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CodexTokenStoreTests`
Expected: FAIL — `cannot find 'CodexTokenStore' in scope`.

- [ ] **Step 3: Add the credential types**

Append to `Sources/ClaudeUsageCore/TokenProviding.swift`:

```swift
/// Codex needs an account id alongside the bearer token, which `TokenLookup`
/// cannot express — hence a sibling type rather than a change to the Claude one.
public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountId: String?

    public init(accessToken: String, accountId: String?) {
        self.accessToken = accessToken
        self.accountId = accountId
    }
}

public enum CodexTokenLookup: Equatable, Sendable {
    case credentials(CodexCredentials)
    case missing
}

public protocol CodexTokenProviding: Sendable {
    func credentials() throws -> CodexTokenLookup
}
```

- [ ] **Step 4: Implement the store**

Create `Sources/ClaudeUsageTokens/CodexTokenStore.swift`. Note there is **no `#if`** — unlike Claude, Codex uses a file on every platform, so one implementation serves all three.

```swift
import ClaudeUsageCore
import Foundation

/// Reads the OAuth token set the Codex CLI writes to `~/.codex/auth.json`
/// (mode 0600), or under `$CODEX_HOME` when that is set. Unlike Claude, Codex
/// uses a file on every platform, so there is no Keychain path here.
///
/// This type never writes. Codex owns the credential and rotates it — the file
/// carries `refresh_token` and `last_refresh` — so there is deliberately no code
/// path here that creates, truncates or modifies it.
public struct CodexTokenStore: CodexTokenProviding {
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
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("auth.json")
        }
        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    public func credentials() throws -> CodexTokenLookup {
        guard FileManager.default.fileExists(atPath: path.path) else {
            // Codex is not signed in on this machine. An expected state.
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: path, options: [])
        } catch {
            throw TokenStoreError.unreadable
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String,
            !token.isEmpty
        else {
            throw TokenStoreError.malformed
        }

        return .credentials(CodexCredentials(
            accessToken: token,
            accountId: tokens["account_id"] as? String
        ))
    }
}
```

- [ ] **Step 5: Prove there is no write path**

Run: `grep -nE 'write|createFile|removeItem|truncate|SecItem' Sources/ClaudeUsageTokens/CodexTokenStore.swift`
Expected: only doc-comment prose ("never writes", "creates, truncates or modifies"). **No executable line may match.** Inspect each hit and confirm it is a comment.

- [ ] **Step 6: Run the suite**

Run: `swift test`
Expected: PASS, 113 on macOS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: read Codex credentials from ~/.codex/auth.json

One implementation for all three platforms — unlike Claude, Codex stores its
token in a file on macOS too, so there is no Keychain path. Read-only by
construction: no code path creates, truncates or modifies the file, because
Codex owns that credential and rotates it.

Carries an account id alongside the token, which the Claude TokenLookup cannot
express, hence a sibling protocol rather than a change to the existing one.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Fetch Codex usage

**Files:**
- Create: `Sources/ClaudeUsageCore/CodexClient.swift`
- Create: `Tests/ClaudeUsageCoreTests/CodexClientTests.swift`

**Interfaces:**
- Consumes: `CodexTokenProviding`, `CodexSnapshot`, `UsageFetching`, `UsageError`.
- Produces: `public struct CodexClient: UsageFetching` with `init(tokens:now:transport:)`, `static let endpoint`, `static var userAgent`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeUsageCoreTests/CodexClientTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct StubCodexTokens: CodexTokenProviding {
    let result: Result<CodexTokenLookup, TokenStoreError>
    func credentials() throws -> CodexTokenLookup { try result.get() }
}

private let signedIn = StubCodexTokens(
    result: .success(.credentials(CodexCredentials(accessToken: "sk-codex-abc", accountId: "acc-1")))
)

private func respond(_ status: Int, _ body: Data) -> UsageClient.Transport {
    { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

@Suite struct CodexClientTests {
    @Test func sendsTheRequiredHeaders() async throws {
        var seen: URLRequest?
        let client = CodexClient(tokens: signedIn, transport: { request in
            seen = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (try Fixture.data("codex-free"), response)
        })

        _ = try await client.fetchUsage()
        let request = try #require(seen)

        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-codex-abc")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acc-1")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == CodexClient.userAgent)
    }

    @Test func omitsTheAccountHeaderWhenThereIsNoAccountId() async throws {
        var seen: URLRequest?
        let tokens = StubCodexTokens(
            result: .success(.credentials(CodexCredentials(accessToken: "t", accountId: nil)))
        )
        let client = CodexClient(tokens: tokens, transport: { request in
            seen = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (try Fixture.data("codex-free"), response)
        })

        _ = try await client.fetchUsage()
        #expect(try #require(seen).value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    @Test func reportsAMissingToken() async {
        let client = CodexClient(
            tokens: StubCodexTokens(result: .success(.missing)),
            transport: respond(200, Data())
        )
        await #expect(throws: UsageError.noToken) { try await client.fetchUsage() }
    }

    @Test(arguments: [401, 403])
    func reportsAnExpiredToken(status: Int) async {
        let client = CodexClient(tokens: signedIn, transport: respond(status, Data()))
        await #expect(throws: UsageError.unauthorized) { try await client.fetchUsage() }
    }

    @Test func reportsUnexpectedStatusCodes() async {
        let client = CodexClient(tokens: signedIn, transport: respond(503, Data()))
        await #expect(throws: UsageError.badStatus(503)) { try await client.fetchUsage() }
    }

    @Test func reportsUndecodableBodies() async {
        let client = CodexClient(tokens: signedIn, transport: respond(200, Data("nope".utf8)))
        await #expect(throws: UsageError.decoding) { try await client.fetchUsage() }
    }

    @Test func treatsAThrownTokenStoreErrorAsUnavailable() async {
        let client = CodexClient(
            tokens: StubCodexTokens(result: .failure(.unreadable)),
            transport: respond(200, Data())
        )
        await #expect(throws: UsageError.tokenStoreUnavailable) { try await client.fetchUsage() }
    }

    @Test func decodesASuccessfulResponse() async throws {
        let client = CodexClient(tokens: signedIn, transport: { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (try Fixture.data("codex-free"), response)
        })

        let snapshot = try await client.fetchUsage()
        #expect(snapshot.provider == .codex)
        #expect(snapshot.primary?.label == "30 days")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CodexClientTests`
Expected: FAIL — `cannot find 'CodexClient' in scope`.

- [ ] **Step 3: Implement the client**

Create `Sources/ClaudeUsageCore/CodexClient.swift`:

```swift
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches ChatGPT Codex usage.
///
/// Codex normally surfaces rate limits as response headers on ordinary API
/// calls, which would cost quota to read. This endpoint returns the same data
/// on a plain GET. It is undocumented and can change without notice, so the
/// decoder fails cleanly rather than crashing.
public struct CodexClient: UsageFetching {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static var userAgent: String { UsageClient.userAgent }

    private let tokens: any CodexTokenProviding
    private let now: @Sendable () -> Date
    private let transport: UsageClient.Transport

    public init(
        tokens: any CodexTokenProviding,
        now: @escaping @Sendable () -> Date = Date.init,
        transport: @escaping UsageClient.Transport = UsageClient.urlSessionTransport
    ) {
        self.tokens = tokens
        self.now = now
        self.transport = transport
    }

    public func fetchUsage() async throws -> ProviderSnapshot {
        let lookup: CodexTokenLookup
        do {
            lookup = try tokens.credentials()
        } catch {
            throw UsageError.tokenStoreUnavailable
        }

        guard case .credentials(let credentials) = lookup else {
            throw UsageError.noToken
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
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
        case 200: break
        case 401, 403: throw UsageError.unauthorized
        default: throw UsageError.badStatus(response.statusCode)
        }

        do {
            return try CodexSnapshot.decode(from: data, fetchedAt: now())
        } catch {
            throw UsageError.decoding
        }
    }
}
```

`UsageFetching` must now return `ProviderSnapshot`; Task 1 changed `UsageClient` to do the same, so no further change is needed there.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test`
Expected: PASS, 122 on macOS.

- [ ] **Step 5: Confirm no credential can reach a log or an error**

Run: `grep -rnE 'print\(|NSLog|FileHandle.standard' Sources/ClaudeUsageCore/`
Expected: no output. `UsageError` cases must remain payload-free.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: fetch Codex usage from the wham/usage endpoint

Codex normally exposes rate limits only as response headers on real API calls,
which would cost quota to read; this endpoint returns the same data on a plain
GET. Sends ChatGPT-Account-Id when the credential file supplies one, and omits
it otherwise.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: One refresh policy per provider

**Files:**
- Modify: `Sources/ClaudeUsageTray/UsageDriver.swift`, `Sources/ClaudeUsageCore/LoginItemControlling.swift` (TrayContent)
- Modify: `Tests/ClaudeUsageTrayTests/UsageDriverTests.swift`
- Create: `Tests/ClaudeUsageTrayTests/MultiProviderDriverTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `TrayContent` gains `states: [(Provider, UsageState)]` in place of a single implied state, preserving `loginItemEnabled`
  - `UsageDriver.init(tray:clients:loginItem:)` where `clients: [(Provider, any UsageFetching)]`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeUsageTrayTests/MultiProviderDriverTests.swift`:

```swift
import ClaudeUsageCore
import Foundation
import Testing
@testable import ClaudeUsageTray

private final class RecordingTray: TrayBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _contents: [TrayContent] = []
    var contents: [TrayContent] { lock.lock(); defer { lock.unlock() }; return _contents }

    func run(handlers: TrayHandlers) -> Never { fatalError("not used in tests") }
    func update(_ content: TrayContent) {
        lock.lock(); _contents.append(content); lock.unlock()
    }
}

private struct FixedClient: UsageFetching {
    let result: Result<ProviderSnapshot, UsageError>
    func fetchUsage() async throws -> ProviderSnapshot { try result.get() }
}

private struct StubLogin: LoginItemControlling {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) {}
}

private func snapshot(_ provider: Provider, _ percent: Int) -> ProviderSnapshot {
    ProviderSnapshot(
        provider: provider,
        planName: nil,
        windows: [UsageWindow(label: "w", percent: percent, resetsAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 100)
    )
}

@Suite struct MultiProviderDriverTests {
    @Test func oneProviderFailingLeavesTheOtherUntouched() async {
        let tray = RecordingTray()
        let driver = UsageDriver(
            tray: tray,
            clients: [
                (.anthropic, FixedClient(result: .success(snapshot(.anthropic, 37)))),
                (.codex, FixedClient(result: .failure(.noToken))),
            ],
            loginItem: StubLogin()
        )

        await driver.refreshAllForTesting()

        let latest = try? #require(tray.contents.last)
        let anthropic = latest?.states.first { $0.0 == .anthropic }?.1
        let codex = latest?.states.first { $0.0 == .codex }?.1

        // Codex being signed out must not disturb the Claude reading.
        #expect(anthropic?.displayPercent == 37)
        #expect(codex?.displayPercent == nil)
    }

    @Test func eachProviderBacksOffIndependently() async {
        let tray = RecordingTray()
        let driver = UsageDriver(
            tray: tray,
            clients: [
                (.anthropic, FixedClient(result: .success(snapshot(.anthropic, 37)))),
                (.codex, FixedClient(result: .failure(.transport))),
            ],
            loginItem: StubLogin()
        )

        await driver.refreshAllForTesting()
        await driver.refreshAllForTesting()

        // Claude succeeded twice so stays at the base interval; Codex failed
        // twice so has backed off. One shared interval could not express this.
        #expect(driver.intervalForTesting(.anthropic) == UsageRefreshPolicy.baseInterval)
        #expect(driver.intervalForTesting(.codex) > UsageRefreshPolicy.baseInterval)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MultiProviderDriverTests`
Expected: FAIL — `UsageDriver` has no `clients:` initialiser.

- [ ] **Step 3: Widen TrayContent**

In `Sources/ClaudeUsageCore/LoginItemControlling.swift`, replace `TrayContent` with:

```swift
public struct TrayContent: Equatable, Sendable {
    /// One entry per configured provider, in `Provider.allCases` order, so the
    /// menu bar and dropdown never reorder between updates.
    public let states: [(Provider, UsageState)]
    public let loginItemEnabled: Bool

    public init(states: [(Provider, UsageState)], loginItemEnabled: Bool) {
        self.states = states
        self.loginItemEnabled = loginItemEnabled
    }

    public static func == (lhs: TrayContent, rhs: TrayContent) -> Bool {
        lhs.loginItemEnabled == rhs.loginItemEnabled
            && lhs.states.count == rhs.states.count
            && zip(lhs.states, rhs.states).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}
```

A tuple array is not automatically `Equatable`, hence the explicit `==` — and `Equatable` matters here because the no-op rebuild guard depends on it.

- [ ] **Step 4: Make the driver hold one policy per provider**

In `Sources/ClaudeUsageTray/UsageDriver.swift`, replace the single `policy`/`isFetching` pair with per-provider dictionaries, and change the initialiser:

```swift
    private let clients: [(Provider, any UsageFetching)]
    private var policies: [Provider: UsageRefreshPolicy]
    private var fetching: Set<Provider> = []

    public init(
        tray: any TrayBackend,
        clients: [(Provider, any UsageFetching)],
        loginItem: any LoginItemControlling
    ) {
        self.tray = tray
        self.clients = clients
        self.loginItem = loginItem
        self.policies = Dictionary(
            uniqueKeysWithValues: clients.map { ($0.0, UsageRefreshPolicy()) }
        )
    }
```

`refresh()` becomes `refresh(_ provider: Provider)` with the in-flight guard keyed on the provider (`fetching.insert` / `fetching.remove` under the existing lock, replacing the `isFetching` boolean). The poll loop and `refreshNow()` iterate all providers. `currentInterval` becomes the **minimum** across providers, so the loop ticks often enough for the most eager one. `publish` builds `states` in `clients` order.

Add two test hooks, marked as such:

```swift
    /// Test hook: drives one full round without the poll loop's sleep.
    func refreshAllForTesting() async {
        for (provider, _) in clients { await refresh(provider) }
    }

    /// Test hook: exposes a provider's backoff interval.
    func intervalForTesting(_ provider: Provider) -> TimeInterval {
        withLock { policies[provider]?.interval ?? 0 }
    }
```

- [ ] **Step 5: Update the existing driver tests**

`UsageDriverTests.swift` constructs `UsageDriver(tray:client:loginItem:)`. Change each to the array form with a single `(.anthropic, client)` entry. The single-in-flight, cleared-on-throw and backoff-progression assertions stay exactly as they are — they now describe the Anthropic provider specifically.

- [ ] **Step 6: Run the suite**

Run: `swift test`
Expected: PASS, 124 on macOS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: one refresh policy per provider

Two independent state machines, each with its own backoff, staleness and
token-rotation tolerance, so Codex being rate-limited or signed out can never
blank the Claude reading, or the reverse. The in-flight guard is keyed by
provider; the poll interval is the minimum across providers.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Render provider sections and a multi-segment title

**Files:**
- Modify: `Sources/ClaudeUsageCore/MenuModel.swift`
- Modify: `Tests/ClaudeUsageCoreTests/MenuModelTests.swift`

**Interfaces:**
- Consumes: `TrayContent.states` from Task 5.
- Produces:
  - `public struct StatusSegment: Equatable, Sendable` — `provider: Provider`, `text: String`, `percent: Int?`, `isCritical: Bool`, `isStale: Bool`
  - `MenuModel.statusSegments(for states: [(Provider, UsageState)]) -> [StatusSegment]`
  - `MenuModel.rows(for states:now:calendar:locale:timeZone:) -> [MenuRow]`
  - `MenuRow` gains `isSectionHeader: Bool`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ClaudeUsageCoreTests/MenuModelTests.swift`:

```swift
extension MenuModelTests {
    private func loaded(_ provider: Provider, _ percent: Int, plan: String? = nil) throws -> UsageState {
        .loaded(ProviderSnapshot(
            provider: provider,
            planName: plan,
            windows: [UsageWindow(label: "Session (5h)", percent: percent, resetsAt: nil)],
            fetchedAt: try date("2026-08-04T07:48:00Z")
        ))
    }

    @Test func buildsOneSegmentPerAvailableProvider() throws {
        let segments = MenuModel.statusSegments(for: [
            (.anthropic, try loaded(.anthropic, 37)),
            (.codex, try loaded(.codex, 4)),
        ])

        #expect(segments.count == 2)
        #expect(segments[0].provider == .anthropic)
        #expect(segments[0].text == "37%")
        #expect(segments[1].provider == .codex)
        #expect(segments[1].text == "4%")
    }

    @Test func omitsAProviderThatIsNotSignedIn() throws {
        let segments = MenuModel.statusSegments(for: [
            (.anthropic, try loaded(.anthropic, 37)),
            (.codex, .noToken),
        ])

        #expect(segments.count == 1)
        #expect(segments[0].provider == .anthropic)
    }

    @Test func fallsBackToADashWhenNoProviderHasAValue() {
        let segments = MenuModel.statusSegments(for: [(.anthropic, .noToken), (.codex, .noToken)])

        #expect(segments.count == 1)
        #expect(segments[0].text == "—")
        #expect(segments[0].percent == nil)
    }

    @Test func marksACriticalSegmentIndependently() throws {
        let segments = MenuModel.statusSegments(for: [
            (.anthropic, try loaded(.anthropic, 95)),
            (.codex, try loaded(.codex, 4)),
        ])

        #expect(segments[0].isCritical)
        #expect(!segments[1].isCritical)
    }

    @Test func headsEachProviderSectionWithItsName() throws {
        let rows = MenuModel.rows(
            for: [(.anthropic, try loaded(.anthropic, 37)), (.codex, try loaded(.codex, 4, plan: "free"))],
            now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )

        let headers = rows.filter(\.isSectionHeader)
        #expect(headers.count == 2)
        #expect(headers[0].label == "CLAUDE")
        #expect(headers[1].label == "CODEX · free")
    }

    @Test func doesNotHeadASingleProviderSection() throws {
        // With only one provider configured the heading is noise.
        let rows = MenuModel.rows(
            for: [(.anthropic, try loaded(.anthropic, 37))],
            now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )
        #expect(rows.filter(\.isSectionHeader).isEmpty)
    }

    @Test func showsEachProvidersErrorUnderItsOwnHeading() throws {
        let rows = MenuModel.rows(
            for: [(.anthropic, try loaded(.anthropic, 37)), (.codex, .noToken)],
            now: try date("2026-08-04T07:48:00Z"),
            calendar: calendar, locale: locale, timeZone: utc
        )
        let labels = rows.map(\.label)
        #expect(labels.contains { $0.contains("Not signed in") })
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MenuModelTests`
Expected: FAIL — no `statusSegments`, no `isSectionHeader`.

- [ ] **Step 3: Add the segment type and section header flag**

In `Sources/ClaudeUsageCore/MenuModel.swift`, add:

```swift
/// One provider's contribution to the menu bar item.
public struct StatusSegment: Equatable, Sendable {
    public let provider: Provider
    public let text: String
    public let percent: Int?
    public let isCritical: Bool
    public let isStale: Bool
}
```

and give `MenuRow` an `isSectionHeader: Bool` (defaulting to `false` in the memberwise init, so every existing call site is unaffected).

- [ ] **Step 4: Implement segments and sectioned rows**

```swift
    public static func statusSegments(for states: [(Provider, UsageState)]) -> [StatusSegment] {
        let segments = states.compactMap { provider, state -> StatusSegment? in
            // A provider with no value contributes nothing rather than a dash —
            // two dashes in the menu bar would be noise.
            guard let percent = state.displayPercent else { return nil }
            let isStale: Bool
            if case .stale = state { isStale = true } else { isStale = false }
            return StatusSegment(
                provider: provider,
                text: Formatting.percentText(percent),
                percent: percent,
                isCritical: Formatting.isCritical(percent),
                isStale: isStale
            )
        }

        guard segments.isEmpty else { return segments }
        return [StatusSegment(
            provider: states.first?.0 ?? .anthropic,
            text: Formatting.percentText(nil),
            percent: nil,
            isCritical: false,
            isStale: false
        )]
    }

    public static func rows(
        for states: [(Provider, UsageState)],
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [MenuRow] {
        let showHeaders = states.count > 1
        return states.flatMap { provider, state -> [MenuRow] in
            var section: [MenuRow] = []
            if showHeaders {
                var heading = provider.displayName.uppercased()
                if let plan = planName(of: state) { heading += " · \(plan)" }
                section.append(MenuRow(label: heading, isSectionHeader: true))
            }
            section.append(contentsOf: rows(
                for: state, provider: provider,
                now: now, calendar: calendar, locale: locale, timeZone: timeZone
            ))
            return section
        }
    }

    private static func planName(of state: UsageState) -> String? {
        switch state {
        case .loaded(let snapshot): return snapshot.planName
        case .stale(let snapshot, _, _): return snapshot.planName
        default: return nil
        }
    }
```

Note the local is named `section`, not `rows` — a local named `rows` would shadow the function being called on the next line.

The existing single-state `rows(for:...)` becomes the per-provider builder the above calls, and gains a `provider` parameter so its messages name the right CLI. Change its signature and the two provider-specific messages:

```swift
    public static func rows(
        for state: UsageState,
        provider: Provider = .anthropic,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [MenuRow] {
        let cli = provider == .anthropic ? "Claude Code" : "Codex"
        switch state {
        case .loading:
            return [MenuRow(label: "Loading…")]
        case .noToken:
            return [MenuRow(label: "Not signed in to \(cli)")]
        case .unauthorized:
            return [MenuRow(label: "Token expired — open \(cli) to refresh")]
        // … remaining cases unchanged apart from the stale one, see Step 5
        }
    }
```

The `provider` default keeps every existing call site and test compiling unchanged.

- [ ] **Step 5: Correct the stale wording while you are here**

The spec requires stale rows to name their cause rather than always saying "Offline", which is wrong for an HTTP 429 or a decode failure — and materially confusing once two providers can each be stale for different reasons. This is the one sanctioned change to `UsageRefreshPolicy` in this plan.

In `Sources/ClaudeUsageCore/UsageRefreshPolicy.swift`, add the reason type and widen the case:

```swift
/// Why a retained value is stale. The row says so, because "Offline" is wrong
/// when the app reached the server fine and was rate limited or sent something
/// it could not parse.
public enum StaleReason: Equatable, Sendable {
    case offline
    case rateLimited
    case serverError
    case badResponse
    case credentials

    public var rowText: String {
        switch self {
        case .offline: return "Offline"
        case .rateLimited: return "Rate limited"
        case .serverError: return "Server error"
        case .badResponse: return "Unexpected response"
        case .credentials: return "Can't read credentials"
        }
    }

    init(_ error: UsageError) {
        switch error {
        case .transport: self = .offline
        case .badStatus(429): self = .rateLimited
        case .badStatus: self = .serverError
        case .decoding: self = .badResponse
        case .tokenStoreUnavailable: self = .credentials
        // An unconfirmed auth failure is a rotation window, not a sign-out.
        case .noToken, .unauthorized: self = .credentials
        }
    }
}
```

Change `case stale(ProviderSnapshot, since: Date)` to `case stale(ProviderSnapshot, since: Date, reason: StaleReason)`, and update the three places `record(failure:)` builds it to pass `StaleReason(failure)`. The `displayPercent` switch needs its binding widened to `case .stale(let snapshot, _, _)`.

Then in `MenuModel`, render it:

```swift
        case .stale(let snapshot, let since, let reason):
            return usageRows(snapshot, now: now, calendar: calendar, locale: locale)
                + [MenuRow(label: "\(reason.rowText) — updated \(Formatting.clockTime(since, locale: locale, timeZone: timeZone))")]
```

Update every existing `.stale(` construction and pattern-match in the tests to the three-element form. **Do not drop any assertion** — a test that asserted the old `"Offline — updated 13:44"` string should now assert the correct cause for the error it injects, which for `.transport` is still `"Offline — updated 13:44"`.

Add one test proving the mapping is real:

```swift
    @Test func namesTheCauseOfStalenessRatherThanAlwaysSayingOffline() {
        var policy = UsageRefreshPolicy()
        policy.record(success: snapshot(percent: 37, at: 100))
        policy.record(failure: .badStatus(429))

        guard case .stale(_, _, let reason) = policy.state else {
            Issue.record("expected stale, got \(policy.state)")
            return
        }
        // The app reached the server fine — calling this "Offline" is a lie.
        #expect(reason == .rateLimited)
    }
```

- [ ] **Step 6: Run the suite**

Run: `swift test`
Expected: PASS. Count rises to roughly 134 on macOS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: provider sections and a multi-segment menu bar title

Each provider contributes one segment showing its primary window, and a
provider with no value contributes nothing rather than a second dash. Section
headings appear only when more than one provider is configured.

Stale rows now name their cause instead of always claiming Offline — wrong for
a 429 or a decode failure, and actively confusing once two providers can each
be stale for different reasons.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Draw the marks and wire the backends

**Files:**
- Create: `Sources/ClaudeUsageTray/ProviderMark.swift` (macOS)
- Modify: `Sources/ClaudeUsageTray/AppKitTray.swift`, `AppIndicatorTray.swift`, `Win32Tray.swift`, `Win32MenuLine.swift`
- Modify: `Sources/ClaudeUsageBar/main.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `StatusSegment`, `MenuRow.isSectionHeader`, `CodexTokenStore`, `CodexClient`.
- Produces: `enum ProviderMark { static func image(for: Provider) -> NSImage }`.

- [ ] **Step 1: Draw the marks**

Create `Sources/ClaudeUsageTray/ProviderMark.swift`:

```swift
#if os(macOS)
import AppKit
import ClaudeUsageCore

/// Monochrome template marks identifying each provider in the menu bar.
///
/// Drawn in code rather than bundled as brand assets: template images adapt to
/// light mode, dark mode and tinted menu bars automatically, and there is no
/// artwork to license or keep in sync. These are recognisable renditions, not
/// pixel-exact logos.
enum ProviderMark {
    static func image(for provider: Provider) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            switch provider {
            case .anthropic: drawAnthropic(in: rect)
            case .codex: drawCodex(in: rect)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = provider.displayName
        return image
    }

    /// Anthropic's mark: a radial burst.
    private static func drawAnthropic(in rect: NSRect) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        for spoke in 0..<6 {
            let angle = Double(spoke) * .pi / 3
            path.move(to: centre)
            path.line(to: NSPoint(
                x: centre.x + CGFloat(cos(angle)) * radius,
                y: centre.y + CGFloat(sin(angle)) * radius
            ))
        }
        path.stroke()
    }

    /// OpenAI's mark: an interlocking hexagonal knot, reduced to a hexagon ring
    /// with an inner node — legible at 14pt, where the full knot is mud.
    private static func drawCodex(in rect: NSRect) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1.4
        let ring = NSBezierPath()
        ring.lineWidth = 1.5
        ring.lineJoinStyle = .round
        for corner in 0..<6 {
            let angle = Double(corner) * .pi / 3 + .pi / 6
            let point = NSPoint(
                x: centre.x + CGFloat(cos(angle)) * radius,
                y: centre.y + CGFloat(sin(angle)) * radius
            )
            corner == 0 ? ring.move(to: point) : ring.line(to: point)
        }
        ring.close()
        ring.stroke()

        let node = radius * 0.34
        NSBezierPath(ovalIn: NSRect(
            x: centre.x - node, y: centre.y - node, width: node * 2, height: node * 2
        )).fill()
    }
}
#endif
```

- [ ] **Step 2: Render the segments in the macOS status item**

In `AppKitTray.renderTitle`, replace the single-image/single-title approach with a composed `NSAttributedString` built from `MenuModel.statusSegments(for: content.states)`: for each segment, an `NSTextAttachment` carrying `ProviderMark.image(for:)` followed by the percentage, separated by two spaces. Apply the existing colour rules per segment — `.systemRed` when critical, `.secondaryLabelColor` when stale, `.labelColor` otherwise — and set `statusItem.button?.image = nil` since the marks now live in the title.

- [ ] **Step 3: Render section headers**

In `AppKitTray.renderMenu`, a row with `isSectionHeader` renders as a small-caps, dimmed, non-selectable item — `NSFont.menuFont(ofSize: 10)` with `.secondaryLabelColor` — and rows with a percentage keep the `UsageRowView` treatment from the previous work.

In `AppIndicatorTray.render`, prefix a header row with a blank line and render it via the same `<tt>` markup path. In `Win32Tray`, add it with `MF_STRING | MF_GRAYED` and no bar (extend `Win32MenuLine.line` to pass headers through unchanged, and add a test for that case).

- [ ] **Step 4: Wire both providers at startup**

In `Sources/ClaudeUsageBar/main.swift`, build both clients and pass them to the driver:

```swift
let driver = UsageDriver(
    tray: tray,
    clients: [
        (.anthropic, UsageClient(tokens: tokens)),
        (.codex, CodexClient(tokens: CodexTokenStore())),
    ],
    loginItem: loginItem
)
```

`CodexTokenStore` needs no `#if` — it is the same on all three platforms.

- [ ] **Step 5: Build, test, and hand-verify on macOS**

```bash
swift test
./Scripts/build-app.sh
pkill -f ClaudeUsageBar; open dist/ClaudeUsageBar.app
```

Check: two marks and two percentages in the menu bar; both provider sections in the dropdown with headings; Claude's rows unchanged from before; the app still readable in dark mode. You cannot verify the Linux or Windows rendering — say so rather than implying otherwise.

- [ ] **Step 6: Update the README**

Describe both providers, where each credential is read from (`~/.claude/.credentials.json` or the macOS Keychain; `~/.codex/auth.json` or `$CODEX_HOME`), state that both are read-only, and note that a provider you are not signed into is simply omitted. Add a line that the Codex endpoint is undocumented and may change.

- [ ] **Step 7: Push and confirm CI**

```bash
git add -A
git commit -m "feat: show both providers in the menu bar and dropdown

Each provider gets a drawn monochrome mark and its primary window percentage,
in fixed order, with per-segment colour. Marks are drawn in code rather than
bundled as brand assets so they adapt to light, dark and tinted menu bars.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -u origin codex-provider
gh run watch
```

Expected: all three jobs green.

---

## Verification boundary

Unchanged from the cross-platform work: the Linux and Windows tray backends still cannot be executed by anyone here, so Task 7's changes to them are proven only to compile. Everything in Tasks 1–6 is core logic and is covered by tests on all three platforms.

New to this plan: the Codex endpoint is undocumented and was verified live exactly once, on a `free` plan. The paid-plan shape — a 5-hour primary with a weekly secondary — is inferred from the Codex source's header families and is covered by a fabricated fixture, not by an observed response.
