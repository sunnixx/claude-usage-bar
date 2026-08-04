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
