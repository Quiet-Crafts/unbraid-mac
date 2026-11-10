#!/bin/bash
# Debug build → /Applications/unbraid.app with a fresh build number, so macOS replaces the system extension.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen -q
BUILD=$(date +%y%m%d%H%M%S | cut -c2-)
mkdir -p build
# A failed build never replaces the installed app, even when Info.plist already carries the new number.
if ! ./tools/xc.sh -project unbraid.xcodeproj -scheme unbraid -configuration Debug -derivedDataPath build/dd CURRENT_PROJECT_VERSION=$BUILD build > build/dev-install.log 2>&1; then
  { grep -E "error:" build/dev-install.log | grep -v nullability | head -20 || true; }; echo "build failed (build/dev-install.log)"; exit 1
fi
APP=build/dd/Build/Products/Debug/unbraid.app
[ "$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleVersion)" = "$BUILD" ] || { echo "build failed"; exit 1; }
osascript -e 'quit app "unbraid"' 2>/dev/null || true; sleep 1
rm -rf /Applications/unbraid.app && ditto "$APP" /Applications/unbraid.app
open -g /Applications/unbraid.app
echo "installed build $BUILD"
