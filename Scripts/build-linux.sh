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
