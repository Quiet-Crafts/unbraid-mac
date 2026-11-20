#!/bin/bash
# Frameworks/Kyber.sha256 describes the whole Kyber library (tools/build-kyber.sh) and what it was built from: the
# SHA-256 of every file in Kyber.xcframework, then of every source file in tools/kyber/ that goes into it. A stale or
# partly rebuilt framework, or a source changed without rebuilding, no longer matches.
#   tools/kyber-manifest.sh           prints that description
#   tools/kyber-manifest.sh --check   compares it with Kyber.sha256 (the Xcode build's "Verify Kyber library" phase,
#                                     tools/release.sh): any changed, missing or extra file fails
#   tools/kyber-manifest.sh --write   records it in Kyber.sha256 (tools/build-kyber.sh, after a build)
# Anything it can't read, list or hash is an error, never a shorter description.
set -euo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/Frameworks"
F=Kyber.xcframework
fail() { echo "$1" >&2; return 1; }
sha() {
  local h
  h=$(shasum -a 256 < "$1") || fail "can't read $1" || return 1
  h=${h%% *}
  [[ $h =~ ^[0-9a-f]{64}$ ]] || fail "can't hash $1" || return 1
  echo "$h"
}
manifest() {
  local entries sorted p h
  [ -d "$F" ] || fail "no Frameworks/$F: run tools/build-kyber.sh" || return 1
  # -H: in a worktree the framework folder may itself be a link to a shared copy; what is inside it is described as is.
  # One name per line, so a name with a control character in it (a newline) is refused rather than split.
  entries=$(find -H "$F" -mindepth 1 -name '*[[:cntrl:]]*') || fail "can't list Frameworks/$F" || return 1
  [ -z "$entries" ] || fail "Frameworks/$F holds a name with a control character" || return 1
  entries=$(find -H "$F" -mindepth 1) || fail "can't list Frameworks/$F" || return 1
  sorted=$(printf '%s\n' "$entries" | sort) || return 1
  while IFS= read -r p; do
    if [ -L "$p" ]; then
      fail "Frameworks/$p is a link" || return 1
    elif [ -d "$p" ]; then
      continue
    elif [ -f "$p" ]; then
      h=$(sha "$p") || return 1
      echo "$h  $p"
    else
      fail "unexpected Frameworks/$p" || return 1
    fi
  done <<EOT
$sorted
EOT
  for p in go.mod go.sum kem.go export.go unbraid_kyber.h module.modulemap; do
    h=$(sha "$ROOT/tools/kyber/$p") || return 1
    echo "source $p $h"
  done
}
case "${1:-}" in
  --check)
    m=$(manifest) || exit 1
    [ "$m" = "$(cat Kyber.sha256)" ] || {
      echo "error: Frameworks/$F is not the library Frameworks/Kyber.sha256 records, or not from tools/kyber (rebuild it with tools/build-kyber.sh):" >&2
      diff <(echo "$m") Kyber.sha256 >&2 || true
      exit 1
    } ;;
  --write)
    m=$(manifest) || exit 1
    echo "$m" > Kyber.sha256.new && mv -f Kyber.sha256.new Kyber.sha256 ;;
  "") manifest ;;
  *) echo "usage: $0 [--check | --write]" >&2; exit 1 ;;
esac
