#!/bin/bash
# Reproducible build of Frameworks/Kyber.xcframework: the two Kyber-1024 operations the app needs for IVPN's quantum-safe
# key (tools/kyber, Round-3 Kyber-1024 from cloudflare/circl), as a small static library for macOS arm64 + x86_64. The
# app links this instead of the whole engine (Libbox), which only the tunnel extension needs.
# The same hash whoever builds it, wherever the checkout is, given the same Xcode: the binary names the clang and SDK it
# was built with, so another Xcode builds an equivalent library with another hash.
set -euo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The macOS version the app targets (project.yml), read from there so the two can't drift apart.
MINOS=$(sed -n 's/^  deploymentTarget: { macOS: "\([0-9.]*\)" }$/\1/p' "$ROOT/project.yml")
[[ $MINOS =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "no macOS deployment target in project.yml"; exit 1; }
# Always the macOS SDK of the selected Xcode ("xcrun --show-sdk-path" alone may name an unrelated command-line SDK).
SDK=$(xcrun --sdk macosx --show-sdk-path)
[ -d "$SDK" ] || { echo "no macOS SDK"; exit 1; }
CC=$(xcrun --sdk macosx --find clang)
# Everything is built from a private copy at a fixed path: -trimpath leaves no builder path in Go's part, and the
# C part is compiled from there too. Taken whole by this build alone and removed when it ends.
B=/tmp/unbraid-kyber
mkdir -m 700 "$B" 2>/dev/null || { echo "$B exists: another build is running (or one was killed: remove it)"; exit 1; }
trap 'rm -rf "$B"' EXIT
mkdir "$B/src" "$B/out" "$B/headers"
cp "$ROOT"/tools/kyber/{go.mod,go.sum,kem.go,export.go} "$B/src/"
cp "$ROOT"/tools/kyber/unbraid_kyber.h "$ROOT"/tools/kyber/module.modulemap "$B/headers/"
# ZERO_AR_DATE: libtool would stamp the archive's symbol table with the time of the build.
export GOTOOLCHAIN=go1.26.11 GOFLAGS=-mod=readonly GOWORK=off GOSUMDB=sum.golang.org \
  GOPROXY=https://proxy.golang.org,direct GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= GONOPROXY= ZERO_AR_DATE=1 \
  CGO_ENABLED=1 CC="$CC" SDKROOT="$SDK" GOBIN="$B/bin"
cd "$B/src"
go mod verify
# The module's own test (round trip, bad input rejected) runs first, on this machine's architecture.
CGO_CFLAGS="-mmacosx-version-min=$MINOS -isysroot $SDK" CGO_LDFLAGS="-mmacosx-version-min=$MINOS -isysroot $SDK" \
  go test -count=1 ./... > "$B/test.log" 2>&1 || { cat "$B/test.log"; echo "the Kyber module's test failed"; exit 1; }
SLICES=()
for pair in arm64:arm64 amd64:x86_64; do
  goarch=${pair%%:*} arch=${pair##*:}
  FLAGS="-arch $arch -mmacosx-version-min=$MINOS -isysroot $SDK -ffile-prefix-map=$B=. -fdebug-prefix-map=$B=."
  GOOS=darwin GOARCH=$goarch CGO_CFLAGS="$FLAGS" CGO_LDFLAGS="$FLAGS" \
    go build -buildmode=c-archive -trimpath -buildvcs=false -ldflags "-s -w -buildid=" -o "$B/out/$arch.go.a" .
  # The members in a fixed order, the archive rebuilt without dates, owners or modes.
  mkdir "$B/out/$arch"
  MEMBERS=$(ar -t "$B/out/$arch.go.a" | grep -v '^__\.SYMDEF')
  [ -z "$(sort <<< "$MEMBERS" | uniq -d)" ] || { echo "$arch: archive members with the same name"; exit 1; }
  (cd "$B/out/$arch" && ar -x "../$arch.go.a" && libtool -static -D -no_warning_for_no_symbols -o "../$arch.a" $MEMBERS)
  SLICES+=("$B/out/$arch.a")
done
mkdir "$B/lib"
lipo -create "${SLICES[@]}" -output "$B/lib/libunbraidkyber.a"
# Nothing in the library may depend on who built it or where.
strings -a "$B/lib/libunbraidkyber.a" > "$B/strings"
LEAKS=("$HOME" /Users/ /var/folders/ go-build "$B")
for leak in "${LEAKS[@]}"; do
  rc=0; grep -qF -- "$leak" "$B/strings" || rc=$?
  [ "$rc" -eq 1 ] || { [ "$rc" -eq 0 ] && echo "the library names a builder path ($leak)"; exit 1; }
done
xcodebuild -create-xcframework -library "$B/lib/libunbraidkyber.a" -headers "$B/headers" -output "$B/Kyber.xcframework" > /dev/null
mkdir -p "$ROOT/Frameworks" && rm -rf "$ROOT/Frameworks/Kyber.xcframework"
mv "$B/Kyber.xcframework" "$ROOT/Frameworks/"
# The Xcode build checks the whole framework and the sources it came from: commit Kyber.sha256 with the change that
# needs the new library.
"$ROOT/tools/kyber-manifest.sh" --write
echo "Frameworks/Kyber.xcframework built: $(du -sh "$ROOT/Frameworks/Kyber.xcframework" | cut -f1)"
