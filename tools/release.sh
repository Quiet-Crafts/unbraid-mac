#!/bin/bash
# Release build: checks and tests → source archive → archive → Developer ID export → notarize → staple → DMG and the
# complete source next to it in dist/ (GPL-3.0 §6: tools/source-archive.sh).
# Needs the Developer ID provisioning profiles named in Config/Signing.xcconfig, a "Developer ID Application" identity
# for its team (SIGN_IDENTITY picks one when there are several), an App Store Connect team API key for notarization
# (ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH, from the environment or .secrets/asc.env: tools/asc.sh), and the engine's
# command-line build for its acceptance tests (tools/build-cli.sh; UNBRAID_SING_BOX names another).
# tools/release.sh --check-only runs every check up to the tests and stops: nothing is archived, signed, notarized or
# tagged.
set -euo pipefail
CHECK_ONLY=0
case "$*" in
  "") ;;
  --check-only) CHECK_ONLY=1 ;;
  *) echo "usage: $0 [--check-only]" >&2; exit 2 ;;
esac
# Xcode lets the xcconfig XCODE_XCCONFIG_FILE names override every other setting, the command line's included.
[ -z "${XCODE_XCCONFIG_FILE+set}" ] || { echo "Unset XCODE_XCCONFIG_FILE first: it would override the release's build settings"; exit 1; }
cd "$(dirname "$0")/.."
ROOT=$PWD
WORK=${WORK:-$HOME/Development/unbraid-mac-deps}
# A release is built from a commit, so it can be traced back to its source. Untracked files count: XcodeGen builds whole
# source folders, so a stray file would ship under a commit without it.
clean() {
  git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain --untracked-files=all)" ] || { echo "$1"; exit 1; }
}
clean "Commit, stash, remove or ignore your changes first"
# The project file is generated: one this Mac's XcodeGen writes differently would build the release from a project the
# commit doesn't have.
xcodegen -q
clean "XcodeGen here writes a different unbraid.xcodeproj than the commit's: commit the regenerated one first"
# Config/Local.xcconfig is ignored by git, so it changes the build without changing the commit. A release refuses one
# unless ALLOW_LOCAL_XCCONFIG=1, and then takes from it only the signing settings Config/Signing.xcconfig names, as plain
# values, prints it, and puts that copy in the source archive.
LOCAL=Config/Local.xcconfig HAD_LOCAL=0 LOCAL_COPY=
if [ -e "$LOCAL" ] || [ -L "$LOCAL" ]; then
  [ "${ALLOW_LOCAL_XCCONFIG:-0}" = 1 ] || { echo "$LOCAL changes what is built: remove it, or set ALLOW_LOCAL_XCCONFIG=1 to release with it"; exit 1; }
  [ ! -L "$LOCAL" ] && [ -f "$LOCAL" ] && [ -r "$LOCAL" ] || { echo "$LOCAL must be a readable file, not a link"; exit 1; }
  HAD_LOCAL=1
fi
COMMIT=$(git rev-parse HEAD) SHORT=$(git rev-parse --short HEAD)
# yymmddHHMMSS: 12 digits, so a release always sorts above the 11-digit development builds (tools/dev-install.sh). In
# UTC: local time steps back when summer time ends or the Mac changes time zone.
BUILD=${BUILD:-$(date -u +%y%m%d%H%M%S)}
# The installed app only replaces its extension with an equal or higher build (TunnelControl): a malformed or oversized
# number would strand every later release, and so would one at or below an earlier release's (its tag or files in dist/).
[[ $BUILD =~ ^[0-9]{12}$ ]] || { echo "BUILD must be 12 digits (yymmddHHMMSS)"; exit 1; }
TAGS=$(git tag -l 'v*-*')
LAST=$( { sed -nE 's/^v.*-([0-9]{12})$/\1/p' <<< "$TAGS"
  [ ! -d dist ] || ls dist | sed -nE 's/^unbraid-.*-([0-9]{12})(\.dmg|-source\.tar\.gz)$/\1/p'; } | sort | tail -1)
[ -z "$LAST" ] || [[ $BUILD > $LAST ]] || { echo "BUILD $BUILD must be above the last release's, $LAST"; exit 1; }
source tools/asc.sh
asc_load
[ "$ASC_READY" = 1 ] || { echo "Notarizing needs an App Store Connect team key: set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (environment or .secrets/asc.env)"; exit 1; }

OUT=build/release; rm -rf "$OUT"; mkdir -p "$OUT" dist
if [ "$HAD_LOCAL" = 1 ]; then
  LOCAL_COPY="$ROOT/$OUT/Local.xcconfig"
  cp "$LOCAL" "$LOCAL_COPY"
  # NAME = value lines (letters, digits, spaces, '.', '-', '_'), each name once, and // comments: no #include, no
  # $(…), no conditions, no other setting. Only printable ASCII: Xcode also ends a line at a lone carriage return or a
  # Unicode line separator, which would hide a line inside a comment (and awk may stop reading a line at a NUL).
  [ "$(LC_ALL=C tr -d '\000' < "$LOCAL_COPY" | wc -c)" -eq "$(wc -c < "$LOCAL_COPY")" ] \
    && LC_ALL=C awk '{ sub(/\r$/, "") } /[^\t -~]/ { exit 1 } /^[ \t]*$/ || /^[ \t]*\/\// { next }
    !/^[ \t]*(DEVELOPMENT_TEAM|BUNDLE_PREFIX|RELEASE_PROFILE_APP|RELEASE_PROFILE_TUNNEL)[ \t]*=[ \t]*[A-Za-z0-9_. -]*[A-Za-z0-9_.-][ \t]*$/ { exit 1 }
    { k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*/, "", k); if (seen[k]++) exit 1 }' "$LOCAL_COPY" \
    || { echo "A release takes only DEVELOPMENT_TEAM, BUNDLE_PREFIX, RELEASE_PROFILE_APP and RELEASE_PROFILE_TUNNEL from $LOCAL, each once as a plain value"; exit 1; }
  echo "$LOCAL (ALLOW_LOCAL_XCCONFIG=1):"; sed 's/^/  /' "$LOCAL_COPY"
fi
# The local override is the one copied above all along (or there is none, as at the start).
local_unchanged() {
  if [ "$HAD_LOCAL" = 1 ]; then
    [ ! -L "$LOCAL" ] && [ -f "$LOCAL" ] && cmp -s "$LOCAL_COPY" "$LOCAL" || { echo "$LOCAL changed during the release"; exit 1; }
  elif [ -e "$LOCAL" ] || [ -L "$LOCAL" ]; then
    echo "$LOCAL appeared during the release"; exit 1
  fi
}
# What the archive is signed with, read back from the Release build settings (Config/Signing.xcconfig and its local
# override), target by target. setting fails on anything it can't read; "optional" turns an unset one into "".
settings() {
  xcodebuild -project unbraid.xcodeproj -target "$1" -configuration Release -showBuildSettings -json > "$OUT/settings-$1.json" 2> "$OUT/settings-$1.log" \
    || { echo "Can't read $1's Release build settings ($OUT/settings-$1.log)"; exit 1; }
}
setting() {
  jq -er --arg k "$2" --arg optional "${3:-}" '
    if type == "array" and length == 1 and (.[0].buildSettings | type) == "object" then .[0].buildSettings else error("unreadable") end
    | if has($k) then .[$k] elif $optional == "optional" then "" else error("unset") end
    | if type == "string" then . else error("not text") end' "$OUT/settings-$1.json" \
    || { echo "Can't read $2 from $1's Release build settings" >&2; return 1; }
}
for t in unbraid UnbraidTunnel UnbraidWidgets; do settings "$t"; done
TEAM=$(setting unbraid DEVELOPMENT_TEAM)
VERSION=$(setting unbraid MARKETING_VERSION)
APP_ID=$(setting unbraid PRODUCT_BUNDLE_IDENTIFIER)
APP_PROFILE=$(setting unbraid PROVISIONING_PROFILE_SPECIFIER)
TUNNEL_ID=$(setting UnbraidTunnel PRODUCT_BUNDLE_IDENTIFIER)
TUNNEL_PROFILE=$(setting UnbraidTunnel PROVISIONING_PROFILE_SPECIFIER)
WIDGET_ID=$(setting UnbraidWidgets PRODUCT_BUNDLE_IDENTIFIER)
[[ $TEAM =~ ^[A-Z0-9]{10}$ ]] && [[ $APP_ID =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] && [ -n "$VERSION" ] && [ -n "$APP_PROFILE" ] && [ -n "$TUNNEL_PROFILE" ] \
  || { echo "Release signing settings incomplete or invalid (Config/Signing.xcconfig)"; exit 1; }
# The code finds the extension and the widgets by these names (Shared/AppGroup.swift).
[ "$TUNNEL_ID" = "$APP_ID.tunnel" ] && [ "$WIDGET_ID" = "$APP_ID.widgets" ] || { echo "The tunnel and widgets must be $APP_ID.tunnel and $APP_ID.widgets"; exit 1; }
echo "Release signing: team $TEAM"
echo "  app      $APP_ID, profile \"$APP_PROFILE\""
echo "  tunnel   $TUNNEL_ID, profile \"$TUNNEL_PROFILE\""
echo "  widgets  $WIDGET_ID"
# Never the DEBUG code in a release: it trusts development-signed copies and keeps keys in a file (AppGroup, Sealed).
# OTHER_SWIFT_FLAGS must be empty, since a flag (or a response file) can define DEBUG in more ways than a pattern sees.
debug='(^|[[:space:]])DEBUG([[:space:]]|$)' conditions='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]*)*$'
for t in unbraid UnbraidTunnel UnbraidWidgets; do
  [ "$(setting "$t" DEVELOPMENT_TEAM)" = "$TEAM" ] || { echo "$t is signed for another team"; exit 1; }
  [ "$(setting "$t" BUNDLE_PREFIX)" = "$APP_ID" ] || { echo "$t has another BUNDLE_PREFIX than $APP_ID"; exit 1; }
  c=$(setting "$t" SWIFT_ACTIVE_COMPILATION_CONDITIONS optional)
  f=$(setting "$t" OTHER_SWIFT_FLAGS optional)
  [[ $c =~ $conditions ]] && ! [[ $c =~ $debug ]] && [ -z "${f//[[:space:]]/}" ] \
    || { echo "$t's Release build would compile the DEBUG code or flags this can't check (SWIFT_ACTIVE_COMPILATION_CONDITIONS: \"$c\", OTHER_SWIFT_FLAGS: \"$f\")"; exit 1; }
done
TAG="v$VERSION-$BUILD" FINAL="dist/unbraid-$VERSION-$BUILD.dmg" SOURCE="dist/unbraid-$VERSION-$BUILD-source.tar.gz"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "Tag $TAG exists already"; exit 1; }
[ ! -e "$FINAL" ] && [ ! -e "$SOURCE" ] || { echo "$FINAL or its source archive exists already"; exit 1; }
# The DMG's signature: the one valid Developer ID Application identity of that team, by its hash, or the one of them
# SIGN_IDENTITY names (by hash or full name).
IDS=$(security find-identity -v -p codesigning | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"\(Developer ID Application: .* ($TEAM)\)\"\$/\1 \2/p")
IDENTITY=$(awk -v want="${SIGN_IDENTITY:-}" 'want == "" || toupper(want) == $1 || want == substr($0, 42) { print $1 }' <<< "$IDS")
[ -n "$IDENTITY" ] && [ "$(grep -c . <<< "$IDENTITY")" -eq 1 ] \
  || { echo "Need exactly one valid Developer ID Application identity for team $TEAM${SIGN_IDENTITY:+ named $SIGN_IDENTITY} (or set SIGN_IDENTITY)"; exit 1; }
echo "  DMG      signed by $(awk -v h="$IDENTITY" '$1 == h { print substr($0, 42) }' <<< "$IDS") ($IDENTITY)"

# The engine: the whole framework tools/build-libbox.sh recorded, built from this commit's patches.
tools/engine-manifest.sh --check
# Scan the patched engine with the same build tags before any release can be tagged.
WORK="$WORK" tools/vulncheck.sh || { echo "Engine vulnerability scan failed"; exit 1; }
# The tests, with the engine's command-line build required (missing, it fails the tests instead of skipping them), then
# their result read back: every test passed, none skipped, the check of every golden config by the engine among them.
CLI=${UNBRAID_SING_BOX:-$WORK/sing-box-cli-mac}
TEST_RUNNER_UNBRAID_SING_BOX="$CLI" xcodebuild test -project unbraid.xcodeproj -scheme UnbraidTests -destination 'platform=macOS' \
  -derivedDataPath "$OUT/tests" -resultBundlePath "$OUT/tests.xcresult" CODE_SIGNING_ALLOWED=NO > "$OUT/tests.log" 2>&1 \
  || { grep -E "error:|failed" "$OUT/tests.log" | head -20; echo "Tests failed ($OUT/tests.log)"; exit 1; }
RESULT=$(xcrun xcresulttool get test-results summary --path "$OUT/tests.xcresult" | jq -r '"\(.result) \(.passedTests) \(.failedTests) \(.skippedTests)"')
[[ $RESULT =~ ^Passed\ [1-9][0-9]*\ 0\ 0$ ]] || { echo "Tests: $RESULT (result, passed, failed, skipped)"; exit 1; }
GOLDEN=$(xcrun xcresulttool get test-results tests --path "$OUT/tests.xcresult" \
  | jq -r '[.. | objects | select(.nodeType? == "Test Case" and .nodeIdentifier? == "CompilerTests/testThePinnedEngineAcceptsEveryGoldenConfig()") | .result] | join(",")')
[ "$GOLDEN" = Passed ] || { echo "The engine didn't check every golden config (${GOLDEN:-not run})"; exit 1; }
echo "Tests: ${RESULT#Passed } (passed, failed, skipped)"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || { echo "HEAD moved during the release"; exit 1; }
clean "The tree changed during the release"
local_unchanged
if [ "$CHECK_ONLY" = 1 ]; then
  echo "Every check before the archive passed (--check-only: no source archive, archive, signature, notarization or tag)"
  exit 0
fi
# The complete source of this release, published next to the DMG: made before anything is signed, so a release never
# goes out without it. The local override goes in with it, and the build number for rebuilding it.
LOCAL_XCCONFIG="$LOCAL_COPY" RELEASE_BUILD="$BUILD" WORK="$WORK" tools/source-archive.sh "$COMMIT" "$OUT/unbraid-$VERSION-$BUILD-source.tar.gz"

./tools/xc.sh -project unbraid.xcodeproj -scheme unbraid -configuration Release -archivePath "$OUT/unbraid.xcarchive" \
  -derivedDataPath "$OUT/dd" CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
P="$OUT/export.plist" PB=/usr/libexec/PlistBuddy
"$PB" -c "Add :method string developer-id" -c "Add :teamID string $TEAM" -c "Add :signingStyle string manual" \
  -c "Add :signingCertificate string Developer ID Application" -c "Add :provisioningProfiles dict" "$P" >/dev/null
"$PB" -c "Add :provisioningProfiles:$APP_ID string $APP_PROFILE" -c "Add :provisioningProfiles:$TUNNEL_ID string $TUNNEL_PROFILE" "$P"
./tools/xc.sh -exportArchive -archivePath "$OUT/unbraid.xcarchive" -exportPath "$OUT/export" -exportOptionsPlist "$P" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
local_unchanged
APP="$OUT/export/unbraid.app"
codesign --verify --deep --strict "$APP"
# Check each exported signature, including the entitlements actually embedded by signing.
check_signature() {
  local bundle=$1 declared=$2 label=$3
  local info="$OUT/signature-$label.txt" ent="$OUT/entitlements-$label.plist"
  [ -d "$bundle" ] || { echo "$label bundle missing: $bundle"; exit 1; }
  codesign --verify --strict "$bundle" || { echo "$label signature verification failed"; exit 1; }
  codesign -dvvv "$bundle" > "$info" 2>&1 || { echo "Can't read $label signature"; exit 1; }
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-fA-F]+\([^)]*runtime[^)]*\)' "$info" \
    && grep -Eq '^Timestamp=.+$' "$info" \
    && grep -Eq "^Authority=Developer ID Application: .+ \($TEAM\)$" "$info" \
    || { echo "$label lacks hardened runtime, a secure timestamp, or the team's Developer ID Application authority"; exit 1; }
  codesign -d --entitlements - --xml "$bundle" > "$ent" 2>/dev/null \
    || { echo "Can't read $label entitlements"; exit 1; }
  python3 - "$declared" "$ent" "$label" "$TEAM" "$APP_ID" <<'PY'
import plistlib
import sys

try:
    with open(sys.argv[1], 'rb') as f:
        declared = plistlib.load(f)
    with open(sys.argv[2], 'rb') as f:
        signed = plistlib.load(f)
    if not isinstance(declared, dict) or not isinstance(signed, dict):
        raise ValueError('entitlements are not dictionaries')
    # Signing adds the application and team identifiers to a bundle with a provisioning profile: allowed, and they
    # must name this team.
    added = {'com.apple.application-identifier', 'com.apple.developer.team-identifier'}
    keys = set(signed)
    if keys - added != set(declared) - added:
        raise ValueError(f'entitlement keys differ: expected {sorted(declared)}, got {sorted(keys)}')
    team = sys.argv[4]
    if 'com.apple.developer.team-identifier' in signed and signed['com.apple.developer.team-identifier'] != team:
        raise ValueError('another team identifier')
    if 'com.apple.application-identifier' in signed and not str(signed['com.apple.application-identifier']).startswith(team + '.'):
        raise ValueError('another application identifier')
    if any(k.startswith('com.apple.security.cs.') or k == 'get-task-allow' or
           k == 'com.apple.security.get-task-allow' for k in keys):
        raise ValueError('forbidden entitlement')
    ne = 'com.apple.developer.networking.networkextension'
    if ne in declared and signed[ne] != ['packet-tunnel-provider-systemextension']:
        raise ValueError('wrong network extension provider entitlement')
    # Every declared value as signed, its build settings filled in for this release (app group and keychain group
    # TEAM.APP_ID, sandbox on): same types too, so true is not 1.
    filled = {'$(TeamIdentifierPrefix)': team + '.', '$(AppIdentifierPrefix)': team + '.', '$(BUNDLE_PREFIX)': sys.argv[5],
              '$(NE_PROVIDER)': 'packet-tunnel-provider-systemextension'}
    def fill(v):
        if isinstance(v, str):
            for setting, value in filled.items():
                v = v.replace(setting, value)
            if '$(' in v:
                raise ValueError(f'unknown build setting in {v}')
            return v
        if isinstance(v, list):
            return [fill(x) for x in v]
        if isinstance(v, dict):
            return {k: fill(x) for k, x in v.items()}
        return v
    for k in set(declared) - added:
        if plistlib.dumps(signed[k]) != plistlib.dumps(fill(declared[k])):
            raise ValueError(f'{k} is {signed[k]!r}, expected {fill(declared[k])!r}')
except (OSError, ValueError, plistlib.InvalidFileException) as e:
    sys.exit(f'{sys.argv[3]} entitlements: {e}')
PY
}
check_signature "$APP" App/unbraid.entitlements app
check_signature "$APP/Contents/Library/SystemExtensions/$TUNNEL_ID.systemextension" Tunnel/Tunnel.entitlements tunnel
check_signature "$APP/Contents/PlugIns/UnbraidWidgets.appex" Widgets/Widgets.entitlements widgets
# Built under a working name: only a notarized, stapled DMG that passes Gatekeeper gets the release name in dist/.
DMG="$OUT/unbraid-$VERSION-$BUILD.dmg"
# The app beside an Applications shortcut, so installing is one drag.
STAGE="$OUT/dmg"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
codesign --verify --deep --strict "$STAGE/unbraid.app"
hdiutil create -volname unbraid -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"
local_unchanged
xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
# Still the commit everything above was built and tested from.
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || { echo "HEAD moved during the release"; exit 1; }
clean "The tree changed during the release"
local_unchanged
mv "$OUT/unbraid-$VERSION-$BUILD-source.tar.gz" "$SOURCE"
mv "$DMG" "$FINAL"
git tag "$TAG" "$COMMIT"
echo "$FINAL and its source, $SOURCE ($SHORT, tagged $TAG): publish both, side by side"
(cd dist && shasum -a 256 "${FINAL#dist/}" "${SOURCE#dist/}")
