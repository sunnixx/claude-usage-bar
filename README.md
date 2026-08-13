# ClaudeUsageBar

A macOS menu bar readout of your Claude subscription usage — the 5-hour
session window at a glance, with the weekly window and per-model scopes in the
dropdown.

![ClaudeUsageBar in the macOS menu bar, showing 7% of the session window used and the dropdown with the weekly window and per-model scopes](docs/images/screenshot.png)

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
