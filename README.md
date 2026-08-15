# ClaudeUsageBar

[![CI](https://github.com/sunnixx/claude-usage-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/sunnixx/claude-usage-bar/actions/workflows/ci.yml)

A macOS, Windows, and Linux menu bar / tray readout of your Claude
subscription usage — the 5-hour session window at a glance, with the weekly
window and per-model scopes in the dropdown.

![ClaudeUsageBar in the macOS menu bar, showing 7% of the session window used and the dropdown with the weekly window and per-model scopes](docs/images/screenshot.png)

The screenshot above is the macOS build. The Windows and Linux trays present
the same information through their platform's own notification-area
conventions — see below.

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

### Linux

    sudo apt install libayatana-appindicator3-dev libgtk-3-dev
    ./Scripts/build-linux.sh

Works on KDE, XFCE, Cinnamon, MATE and Budgie. **GNOME** hides tray icons
unless the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/)
is installed — that applies to every tray app, not just this one.

The token is read from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`),
read-only. Nothing here ever writes it.

### Windows

    swift build -c release

The tray shows the percentage drawn into the icon, because the Windows
notification area has no text field beside an icon. The tooltip carries the
same reading. Left-click or right-click the icon for the menu.

The token is read from `%USERPROFILE%\.claude\.credentials.json` (or
`%CLAUDE_CONFIG_DIR%`), read-only.

## Verification boundary

The macOS build is hand-verified end to end. The Linux and Windows tray
backends are proven only to compile, link, and pass the shared logic tests in
CI — hosted CI runners have no desktop shell, so `AppIndicatorTray` and
`Win32Tray` have never actually been run, by anyone, on a real Linux or
Windows machine. Expect a round of fixes once real users exercise them.

This is a deliberate consequence of the architecture, not an oversight: all
the logic that decides *what number to show* — parsing the usage response,
computing percentages, deciding what's stale or critical, reading the token —
lives in `ClaudeUsageCore`, which every platform shares and which is fully
tested. The platform-specific tray backends only *display* what the core
already computed. A backend bug can draw the wrong pixels, misplace a menu
item, or crash the tray; it cannot show a wrong number or touch your
credential.

## Test

    swift test

86 tests on macOS, 94 on Linux and Windows — the extra 8 cover the
file-based token store (`#if !os(macOS)`), which macOS doesn't use because it
reads the Keychain instead. Everything is covered except the platform UI
layers themselves: `AppKitTray`, `AppIndicatorTray`, `Win32Tray`, the
platform login-item implementations, and the `SecItemCopyMatching` call are
verified by hand on macOS and, per the verification boundary above, not yet
run at all on Linux or Windows.

## Requirements

- **macOS** 14+, Swift 6, Claude Code signed in.
- **Linux**: `libayatana-appindicator3` and GTK3 (see the Linux section
  above), and a desktop that shows tray icons — GNOME needs the
  [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/).
- **Windows** 10+.
