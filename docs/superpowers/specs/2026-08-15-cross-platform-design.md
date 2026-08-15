# ClaudeUsageBar — Windows and Linux Support

**Date:** 2026-08-15
**Status:** Approved
**Supersedes:** nothing. Extends `2026-08-04-claude-usage-bar-design.md`, which
remains the authority on what the app does and why.

## Purpose

Run the same usage readout on Windows and Linux as it does on macOS, from one
Swift codebase, without weakening the macOS app or the tested core.

## What stays the same

The product does not change. It is still a readout: one percentage in the
tray, the rest in a dropdown, silent at every threshold, polling
`https://api.anthropic.com/api/oauth/usage` once a minute with a token it
only ever reads.

The refresh policy, backoff, error handling, and token-rotation tolerance are
untouched. The two rulings already recorded stand: a confirmed sign-out drops
the value permanently, and a single auth failure does not.

## Constraints

**Token access stays read-only on every platform.** Claude Code owns the
credential and rotates it. On macOS the Keychain API made a write a
deliberate act; on Linux and Windows the credential is an ordinary file, so a
careless write would corrupt it and break the user's CLI login. The token
store target contains no write call, opens the file read-only, and is
reviewed on that basis.

**The token is never logged, printed, written, or placed in an error value.**
Its only egress remains the usage endpoint. `UsageError` cases stay
payload-free.

**No new runtime dependency on macOS.** The macOS build must not acquire GTK
or anything else in service of the other platforms.

## Verification boundary

This is a design decision, not a caveat.

CI on `macos-latest`, `ubuntu-latest`, and `windows-latest` proves: the core
logic passes its tests on all three platforms, the file-based token store
passes its tests on all three, and the Linux and Windows code compiles and
links.

CI cannot prove that a tray icon appears or behaves correctly on Windows or
Linux, because hosted runners have no desktop shell. Those two backends are
written from documentation and will not have been executed before release.
They are expected to need a round of fixes from someone with the hardware.

The architecture is shaped around that fact: everything unverifiable is
pushed behind one protocol, so that a broken backend cannot produce a wrong
*number*. The worst a bad backend can do is display badly.

## Target layout

`ClaudeUsageCore` becomes genuinely portable — `import Security` leaves it.

```
ClaudeUsageCore      Foundation only, no platform APIs
                     UsageClient · UsageSnapshot · UsageRefreshPolicy
                     MenuModel · Formatting · ISO8601Flexible
                     TokenProviding (protocol)

ClaudeUsageTokens    KeychainTokenStore.swift          #if os(macOS)
                     CredentialsFileTokenStore.swift   #if os(Linux) || os(Windows)

ClaudeUsageTray      TrayBackend.swift        (protocol, all platforms)
                     AppKitTray.swift         #if os(macOS)
                     AppIndicatorTray.swift   #if os(Linux)
                     Win32Tray.swift          #if os(Windows)

ClaudeUsageBar       executable: driver + LoginItem per platform

CAppIndicator        systemLibrary + module map, Linux only
```

The existing `TokenProviding` protocol already sits at the right seam, so the
token work is additive rather than a refactor. Platform targets are selected
in `Package.swift` with `.when(platforms:)` so that no platform builds
another's dependencies.

### FoundationNetworking

On Linux and Windows `URLSession` lives in `FoundationNetworking`, not
`Foundation`. `UsageClient` gains:

```swift
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

Linux builds link dynamically. Static linking against FoundationNetworking is
broken upstream (swift-corelibs-foundation #3226, #5092), and GTK is a runtime
dependency on Linux regardless, so nothing is lost.

## Token stores

macOS is unchanged.

Linux and Windows read `.credentials.json` from the Claude config directory:
`$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude` (Linux) or
`%USERPROFILE%\.claude` (Windows).

`CredentialsFileTokenStore` takes an **injected path**, so it is fully
unit-testable from fixture files — better coverage than the Keychain store
can have, since no GUI prompt is involved.

Error mapping parallels the Keychain store:

| Condition | Result |
|---|---|
| File absent | `.missing` — an expected "not signed in" state, not an error |
| Unreadable (permissions) | throws → `.tokenStoreUnavailable` |
| Malformed JSON, or token absent/empty | throws → `.tokenStoreUnavailable` |

`UsageError.keychainUnavailable` is renamed `tokenStoreUnavailable`, since it
is no longer Keychain-specific. Its transient handling is unchanged: it never
blanks a good value.

Its menu text is the one user-facing string that must differ by platform,
because the remedy differs. `MenuModel` selects it with `#if os(macOS)`:

| Platform | Row text |
|---|---|
| macOS | `Keychain access denied — allow in Keychain Access` |
| Linux, Windows | `Can't read Claude Code credentials` |

Each is asserted by a test compiled only for its own platform.

**Assumption to verify during implementation:** that `.credentials.json`
carries the same `claudeAiOauth.accessToken` shape as the Keychain item. The
documentation confirms the file's location and mode but not its schema. The
parser fails cleanly to `.tokenStoreUnavailable` rather than crashing if the
shape differs, and the file is never rewritten to "fix" it.

## The Windows tray constraint

`Shell_NotifyIcon` provides a 16×16 icon and a tooltip. There is no
equivalent of `NSStatusItem`'s title or `app_indicator_set_label`, so
Windows **cannot** render `◔ 37%` as text beside an icon.

Windows therefore draws the number into the icon bitmap: a GDI-rendered
32×32 icon showing the percentage, converted to an `HICON` and passed to
`Shell_NotifyIcon` with `NIM_MODIFY` on each update. The full `◔ 37%` text
also goes in the tooltip. This is the established approach for percentage
readouts on Windows.

Consequence: the critical (red) and stale (dimmed) treatments become icon
colours on Windows rather than text colours. Old `HICON`s must be destroyed
after replacement or the app leaks a GDI handle per poll — once a minute,
which would matter within hours.

This requires `StatusTitle` to expose the number, not only the formatted
string, since Windows draws the digits itself and must not parse `"◔ 37%"`
back apart:

```swift
public struct StatusTitle: Equatable, Sendable {
    public let text: String     // "◔ 37%" — macOS and Linux display this
    public let percent: Int?    // 37 — Windows draws this into the icon; nil → "—"
    public let isCritical: Bool
    public let isStale: Bool
}
```

## Run loop and threading

Each platform owns its UI thread differently: `NSApplication.run()`,
`gtk_main()`, `GetMessage`/`DispatchMessage`. The backend owns the loop; the
driver stays platform-neutral.

```swift
public protocol TrayBackend: AnyObject {
    var onRefreshRequested: (() -> Void)? { get set }
    var onToggleLoginItem: (() -> Void)? { get set }
    var onQuit: (() -> Void)? { get set }

    func run()                                           // blocks, owns the UI thread
    func update(_ title: StatusTitle, _ rows: [MenuRow]) // callable from any thread
}
```

The polling loop and `UsageRefreshPolicy` are unchanged. `update` is called
from the polling task and each backend marshals to its own UI thread
internally:

| Platform | Marshalling |
|---|---|
| macOS | `DispatchQueue.main` |
| Linux | `g_idle_add` |
| Windows | `PostMessage` to the hidden message window |

That marshalling is the likeliest source of platform bugs, which is why it is
confined to one method per backend. Touching GTK or Win32 UI objects from the
polling thread is a defect, not a style preference.

## MenuModel

`MenuRow` carries fields instead of one pre-padded string:

```swift
public struct MenuRow: Equatable, Sendable {
    public let label: String
    public let percent: Int?
    public let bar: String?
    public let reset: String?
    public let isIndented: Bool
}
```

Message-only rows ("Not signed in to Claude Code", "Updated 17:25") use
`label` with the rest nil.

Each backend lays the fields out natively:

| Platform | Layout |
|---|---|
| macOS | the current padded monospace columns, byte-identical to today |
| Linux | `<tt>` Pango markup in the GTK menu item |
| Windows | the fields in a proportional Win32 menu |

macOS keeps `labelWidth = 14` and `percentWidth = 4`, and keeps composing the
`└ ` indent inside the padded label so indented rows stay aligned — the fix
from `0ef512c` must survive this refactor.

Tests move from asserting character positions to asserting field values. This
is the point: the earlier column-misalignment bug survived review because the
tests pinned the padded string, which was correct in isolation while the
rendered result was wrong.

## Launch at Login

| Platform | Mechanism |
|---|---|
| macOS | `SMAppService.mainApp` (unchanged) |
| Windows | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value |
| Linux | `~/.config/autostart/claude-usage-bar.desktop` |

Each is behind a `LoginItemControlling` protocol with `isEnabled` and
`setEnabled`, so the driver does not branch on platform.

## Packaging

| Platform | Output |
|---|---|
| macOS | `.app` bundle, ad-hoc signed (`Scripts/build-app.sh`, unchanged) |
| Linux | binary + `.desktop` file + PNG icon, in a tarball |
| Windows | `.exe` with an embedded icon resource |

Out of scope: installers, AppImage/Flatpak/winget packaging, Windows code
signing, notarization.

The Windows `.exe` keeps the default file icon: SwiftPM has no hook for the
resource compiler. The tray icon is generated at runtime, so this affects only
how the binary looks in Explorer.

## Testing

- **Core** — every existing test runs unchanged on all three platforms in CI.
- **`CredentialsFileTokenStore`** — new tests over fixture files: valid,
  absent, malformed JSON, empty token, missing `claudeAiOauth` key, and
  `CLAUDE_CONFIG_DIR` override. Runs on all three platforms; the store is not
  compiled on macOS, so those tests are `#if !os(macOS)`.
- **`MenuModel`** — rewritten to assert field values; a macOS-only test
  asserts the composed monospace line, preserving today's alignment coverage.
- **Not automated** — the three tray backends and the three login-item
  mechanisms. macOS is verified by hand as before; Windows and Linux are
  unverified until someone runs them. See "Verification boundary".

CI matrix: `macos-latest`, `ubuntu-latest`, `windows-latest`, each running
`swift build` and `swift test`. Ubuntu installs
`libayatana-appindicator3-dev` and `libgtk-3-dev` first.

## Implementation order

The work is sequenced so that everything verifiable lands and is proven before
anything unverifiable begins, and so that macOS is never left broken.

1. **Portable core** — move `Security` out of `ClaudeUsageCore`, add the
   conditional `FoundationNetworking` import, split the targets, rename
   `keychainUnavailable`. macOS still builds and all tests still pass.
2. **`MenuRow` restructure** — fields instead of a padded string; the macOS
   renderer composes the identical line it produces today.
3. **`CredentialsFileTokenStore`** — the new store and its tests.
4. **CI matrix** — all three platforms building and testing. This is the gate:
   steps 1–3 are proven on Windows and Linux before any tray code exists.
5. **`TrayBackend` protocol + macOS backend** — today's AppKit code moved
   behind the protocol, verified by hand on this machine.
6. **Linux backend** — AppIndicator C interop, compiled in CI, unrun.
7. **Windows backend** — Win32 + GDI icon rendering, compiled in CI, unrun.

Steps 6 and 7 are independent of each other; either can ship without the
other.

## Out of scope

Unchanged from the original design: no notifications, no history, no cost
accounting, no Console org spend, no token refresh. Additionally: no BSD or
other Unix support, no Wayland-specific work beyond what AppIndicator
provides, and no attempt to make GNOME show a tray icon without the
AppIndicator extension — that limitation applies to every tray app and is not
this app's to fix.

## Open questions

None.
