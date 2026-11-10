#!/bin/bash
# Renders tools/icon/AppIcon.svg (the icon's source) into every size of the app's AppIcon set, and the README's
# .github/icon.png.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SET="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
BIN=$(mktemp -d); trap 'rm -rf "$BIN"' EXIT
swiftc -O "$ROOT/tools/render-svg.swift" -o "$BIN/render-svg" 2>/dev/null
for n in 1024 512 256 128 64 32 16; do "$BIN/render-svg" "$ROOT/tools/icon/AppIcon.svg" "$SET/icon_$n.png" "$n"; done
cp "$SET/icon_512.png" "$ROOT/.github/icon.png"
