#!/usr/bin/env bash
# Builds the Linux binary and stages a tarball in dist/.
# Requires: libayatana-appindicator3-dev libgtk-3-dev
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

STAGE="dist/headroom-linux"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$(swift build -c release --show-bin-path)/Headroom" "$STAGE/headroom"
cp Resources/headroom.desktop "$STAGE/"

tar -czf dist/headroom-linux.tar.gz -C dist headroom-linux
echo "Built dist/headroom-linux.tar.gz"
