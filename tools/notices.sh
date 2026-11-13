#!/bin/bash
# Writes Resources/notices.txt: every licence the app must carry. Run after tools/build-libbox.sh (it does).
# Go modules are the ones actually linked into libbox, for the same build tags.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=${WORK:-$HOME/Development/unbraid-mac-deps}/sing-box
TAGS=$(sed -n 's/.*-tags \([^ ]*\).*/\1/p' "$ROOT/tools/build-libbox.sh")
export GOTOOLCHAIN=go1.26.11 GOFLAGS=-mod=mod GOWORK=off GOSUMDB=sum.golang.org \
  GOPROXY=https://proxy.golang.org,direct GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= GONOPROXY=
OUT="$ROOT/Resources/notices.txt"
mkdir -p "$(dirname "$OUT")"
licence() { ls "$1" | grep -iE '^(LICEN[CS]E|COPYING)' | head -1; }
# A file printed whole, its last line ended even when the file doesn't end it, so the blank line before the next notice
# stays a blank line.
text() { awk 1 "$1"; }
# A plain Apache-2.0 text is printed once, at the end; a longer file (extra licences appended) is kept whole.
show() { if grep -q "Version 2.0, January 2004" "$1" && [ "$(wc -c < "$1")" -lt 11800 ]; then echo "Licensed under the Apache License, Version 2.0 (full text at the end)."; else text "$1"; fi; }
deps() { (cd "$SB" && GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go list -modfile "$MOD/go.mod" -tags "$TAGS" -deps -f "$1" ./experimental/libbox) | sort -u; }
PKGS=$(mktemp); MOD=$(mktemp -d); trap 'rm -f "$PKGS"; rm -rf "$MOD"' EXIT
# Read through a copy of go.mod without the patched sing-openvpn tools/build-libbox.sh builds in its place: that folder
# is gone once the build ends. The module, its imports and its licence are the same unpatched; the checkout isn't written.
cp "$SB/go.mod" "$SB/go.sum" "$MOD/"
go mod edit -dropreplace github.com/sagernet/sing-openvpn "$MOD/go.mod"
deps '{{.Dir}}' > "$PKGS" # folders of the packages actually linked
{
  echo "=== unbraid"
  echo "Copyright (C) 2026 the unbraid authors. GNU General Public License v3.0 or later:"
  text "$ROOT/LICENSE"
  for f in "$ROOT"/tools/notices/*.txt; do [ "${f##*/}" = apache-2.0.txt ] || { echo; text "$f"; }; done
  echo; echo "=== Go standard library and runtime"; text "$(cd "$SB" && go env GOROOT)/LICENSE"
  # The Objective-C bindings: gobind's generated code links the gomobile in sing-box's go.mod.
  v=$(awk '$1 == "github.com/sagernet/gomobile" {print $2}' "$SB/go.mod"); d=$(go env GOMODCACHE)/github.com/sagernet/gomobile@$v
  echo; echo "=== github.com/sagernet/gomobile $v (Objective-C bindings)"; text "$d/$(licence "$d")"
  deps '{{with .Module}}{{.Path}} {{or .Version "-"}} {{.Dir}}{{end}}' | while read -r p v d; do
      [ "$v" = - ] && v= # the main module (sing-box) has no version
      echo; echo "=== $p${v:+ $v}"
      show "$d/$(licence "$d")"
      # NOTICE/COPYRIGHT files, and the licences in subfolders that hold (or sit above) linked code.
      { find "$d" -maxdepth 1 -type f \( -iname 'NOTICE*' -o -iname 'COPYRIGHT*' \)
        find "$d" -mindepth 2 -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) ! -name '*.go' ! -path '*/.github/*' ! -path '*/testdata/*'
      } | sort | while read -r n; do grep -q "^${n%/*}\(/\|$\)" "$PKGS" || continue; echo; echo "--- ${n#$d/}"; show "$n"; done
    done
  echo; echo "=== Apache License 2.0"; text "$ROOT/tools/notices/apache-2.0.txt"
} > "$OUT"
echo "$(grep -c '^=== ' "$OUT") notices, $(wc -c < "$OUT") bytes in ${OUT#$ROOT/}"
