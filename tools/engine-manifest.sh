#!/bin/bash
# Frameworks/Libbox.sha256 describes the whole engine framework and what it was built from, so a stale or partly
# rebuilt framework can't pass for the one tools/build-libbox.sh made: the SHA-256 of every file (the static library
# first, then its headers, module map and plists), the target of every link inside it, then the sing-box commit and the
# SHA-256 of each patch in tools/ (as tools/build-cli.sh stamps them). A patch changed without rebuilding the engine no
# longer matches.
#   tools/engine-manifest.sh                prints that description for Frameworks/Libbox.xcframework and tools/
#   tools/engine-manifest.sh --check        compares it with Libbox.sha256 (the Xcode build's "Verify engine" phase,
#                                           tools/release.sh): any changed, missing or extra file or link fails
#   tools/engine-manifest.sh --write        records it in Libbox.sha256 (tools/build-libbox.sh, after a build)
#   tools/engine-manifest.sh --provenance   prints only the commit and patch lines
# Anything it can't read, list or hash is an error, never a shorter description.
set -euo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/Frameworks"
F=Libbox.xcframework
B=$F/macos-arm64_x86_64/Libbox.framework/Versions/A/Libbox
fail() { echo "$1" >&2; return 1; }
sha() {
  local h
  h=$(shasum -a 256 < "$1") || fail "can't read $1" || return 1
  h=${h%% *}
  [[ $h =~ ^[0-9a-f]{64}$ ]] || fail "can't hash $1" || return 1
  echo "$h"
}
provenance() {
  local pin p h
  pin=$(sed -n 's/^PIN=\([0-9a-f]\{40\}\)$/\1/p' "$ROOT/tools/build-libbox.sh") || return 1
  [[ $pin =~ ^[0-9a-f]{40}$ ]] || fail "no PIN in tools/build-libbox.sh" || return 1
  echo "source $pin"
  for p in "$ROOT"/tools/sing-box-*.patch "$ROOT"/tools/sing-openvpn-*.patch; do
    [ -f "$p" ] || fail "no engine patches in tools/" || return 1
    h=$(sha "$p") || return 1
    echo "patch ${p##*/} $h"
  done
}
manifest() {
  local entries sorted p t h
  [ -f "$B" ] && [ ! -L "$B" ] || fail "no engine at Frameworks/$B: run tools/build-libbox.sh" || return 1
  h=$(sha "$B") || return 1
  echo "$h  $B"
  # -H: in a worktree the framework folder may itself be a link to a shared copy; what is inside it is described as is.
  # One name per line, so a name with a control character in it (a newline) is refused rather than split.
  entries=$(find -H "$F" -mindepth 1 -name '*[[:cntrl:]]*') || fail "can't list Frameworks/$F" || return 1
  [ -z "$entries" ] || fail "Frameworks/$F holds a name with a control character" || return 1
  entries=$(find -H "$F" -mindepth 1) || fail "can't list Frameworks/$F" || return 1
  sorted=$(printf '%s\n' "$entries" | sort) || return 1
  while IFS= read -r p; do
    if [ -L "$p" ]; then
      # Read whole: a target ending in a newline would otherwise look like one without.
      t=$(readlink -n "$p" && echo .) || fail "can't read the link Frameworks/$p" || return 1
      t=${t%.}
      case "$t" in '' | /* | *..* | *[[:cntrl:]]*) fail "Frameworks/$p links outside the framework" || return 1 ;; esac
      echo "link $t  $p"
    elif [ -d "$p" ]; then
      continue
    elif [ -f "$p" ]; then
      [ "$p" = "$B" ] && continue
      h=$(sha "$p") || return 1
      echo "$h  $p"
    else
      fail "unexpected Frameworks/$p" || return 1
    fi
  done <<EOF
$sorted
EOF
  provenance
}
case "${1:-}" in
  --check)
    m=$(manifest) || exit 1
    [ "$m" = "$(cat Libbox.sha256)" ] || {
      echo "error: Frameworks/$F is not the engine Frameworks/Libbox.sha256 records, or not from these patches (rebuild it with tools/build-libbox.sh):" >&2
      diff <(echo "$m") Libbox.sha256 >&2 || true
      exit 1
    } ;;
  --write)
    m=$(manifest) || exit 1
    echo "$m" > Libbox.sha256.new && mv -f Libbox.sha256.new Libbox.sha256 ;;
  --provenance) provenance ;;
  "") manifest ;;
  *) echo "usage: $0 [--check | --write | --provenance]" >&2; exit 1 ;;
esac
