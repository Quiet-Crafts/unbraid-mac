#!/bin/bash
# The smoothness matrix (App/PerfHarness.swift): times page switches, search, scrolling, resizing and the rest in the
# real window, in a throwaway unsigned copy with fake routes and traffic. It has no VPN entitlement, no keychain and its
# own home folder, so a running unbraid and its tunnel are left alone. Its window shows for about a minute.
#   tools/perf.sh                     optimized build, whole matrix
#   tools/perf.sh debug               as the Debug install was: unoptimized
#   ONLY=switch,search tools/perf.sh  only those measurements
#   SAMPLE=switch.all tools/perf.sh   also a call graph of that step (path printed as [Sample])
#   SHOTS=<folder> tools/perf.sh      no timing: pictures for the README and the website, made-up data only (Apple's own
#                                     apps, four made-up routes and accounts, no network), light and dark, as macOS draws
#                                     the windows: All Apps, a route, Direct, Blocked, Traffic, Activity and Speed Test
#                                     (apps, route, direct, blocked, traffic, activity, speed), the same five without Direct
#                                     and Blocked at the smallest window, 770x564 (min-apps, min-route, min-traffic,
#                                     min-activity, min-speed), the location picker (picker), the menu bar panel (panel) and
#                                     every Settings pane (settings-general, -providers, -home, -tailscale, -protection,
#                                     -statistics, -about); dark ones end in -dark
#   EMPTY=1 SHOTS=<folder> tools/perf.sh   the same pages and panel with no traffic at all, as on a first day
#                                     (empty-apps, empty-route, ..., empty-min-*, empty-panel, with -dark too)
#   FAKE=1 HOLD=1 tools/perf.sh       stays open with that same made-up setup
#   HOLD=1 tools/perf.sh              no timing: stays open with the fake data, to try things by hand
#   HOLD=1 UNBRAID_PERF_SELECT=4 tools/perf.sh   the same, with the first four rows already selected
#                                     (UNBRAID_PERF_DARK=1 too for dark mode)
#   CHECKS=<folder> tools/perf.sh     no timing: drives the apps list with real clicks and checks the outcome, then
#                                     leaves pictures (dark mode, a selection, a tool row) in the folder
#   STRESS=1 CHECKS=<folder> tools/perf.sh   redraws the list 1,500 times instead; prints "[Check] stress done" if it lives
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=${1:-opt}
DD=$PWD/build/perf-$MODE
FLAGS=(CODE_SIGNING_ALLOWED=NO)
[ "$MODE" = debug ] || FLAGS+=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule ENABLE_DEBUG_DYLIB=NO)
if [ -z "${NOBUILD:-}" ]; then
  xcodebuild -project unbraid.xcodeproj -scheme unbraid -configuration Debug -derivedDataPath "$DD" "${FLAGS[@]}" build > "$DD.log" 2>&1 \
    || { grep -E "error:" "$DD.log" | grep -v nullability | head -20; echo "build failed ($DD.log)"; exit 1; }
fi
APP=$DD/Build/Products/Debug/unbraid.app
# Its own identity: separate preferences, and the harness refuses to run under any other.
plutil -replace CFBundleIdentifier -string app.unbraid.perf "$APP/Contents/Info.plist"
codesign -f -s - "$APP" 2>/dev/null
PERF_HOME=$(mktemp -d "${TMPDIR:-/tmp}/unbraid-perf-home/XXXXXX" 2>/dev/null || { mkdir -p "${TMPDIR:-/tmp}/unbraid-perf-home"; mktemp -d "${TMPDIR:-/tmp}/unbraid-perf-home/XXXXXX"; })
# The copy's preferences live in macOS's preferences service, outside the home folder above. Clear that one domain (the
# test copy's own, never the real app's) before the run, so it starts clean, and after it.
PERF_DOMAIN=app.unbraid.perf
trap 'rm -rf "$PERF_HOME"; defaults delete "$PERF_DOMAIN" 2>/dev/null || true' EXIT
defaults delete "$PERF_DOMAIN" 2>/dev/null || true
[ -z "${SHOTS:-}" ] || mkdir -p "$SHOTS"
[ -z "${CHECKS:-}" ] || mkdir -p "$CHECKS"
# One complete NAME=value string per setting, so a folder with spaces or wildcards in its name stays one value.
VARS=(UNBRAID_PERF=1 "CFFIXED_USER_HOME=$PERF_HOME")
[ -z "${ONLY:-}" ] || VARS+=("UNBRAID_PERF_ONLY=$ONLY")
[ -z "${SAMPLE:-}" ] || VARS+=("UNBRAID_PERF_SAMPLE=$SAMPLE")
[ -z "${REPS:-}" ] || VARS+=("UNBRAID_PERF_REPS=$REPS")
[ -z "${SHOTS:-}" ] || VARS+=("UNBRAID_PERF_SHOTS=$SHOTS")
[ -z "${EMPTY:-}" ] || VARS+=(UNBRAID_PERF_EMPTY=1)
[ -z "${HOLD:-}" ] || VARS+=(UNBRAID_PERF_HOLD=1)
[ -z "${FAKE:-}" ] || VARS+=(UNBRAID_PERF_FAKE=1)
[ -z "${STRESS:-}" ] || VARS+=(UNBRAID_PERF_STRESS=1)
[ -z "${CHECKS:-}" ] || VARS+=(UNBRAID_PERF_CHECKS=1 "UNBRAID_PERF_CHECK_SHOTS=$CHECKS")
env "${VARS[@]}" \
  caffeinate -d -u -t 300 "$APP/Contents/MacOS/unbraid" 2>&1 | tee "$DD.out" | grep -E "^\[(Perf|Sample|Check)\]|refused"
