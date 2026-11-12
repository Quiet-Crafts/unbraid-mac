#!/bin/bash
# Reproducible build of Frameworks/Libbox.xcframework (sing-box v1.14.4, macOS arm64 + x86_64, unbraid patches): the
# same hash whoever builds it, wherever WORK is, given the same Xcode: the binary names the clang and SDK version it was
# built with, so another Xcode builds an equivalent engine with another hash.
set -euo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/Development/unbraid-mac-deps}
# Absolute: the build changes folders, and the check below looks for "$WORK/" in the binary.
case "$WORK" in /*) ;; *) echo "WORK must be an absolute path"; exit 1 ;; esac
# The patched sing-openvpn is built from a fixed path: Go records a replaced module's directory in the binary, so one under
# $WORK or $HOME would name the builder and make the hash depend on where the build ran. Taken whole by this build alone,
# before anything else, and removed when it ends.
OVPN_ROOT=/tmp/unbraid-libbox OVPN=/tmp/unbraid-libbox/sing-openvpn
mkdir -m 700 "$OVPN_ROOT" 2>/dev/null || { echo "$OVPN_ROOT exists: another build is running (or one was killed: remove it)"; exit 1; }
trap 'rm -rf "$OVPN_ROOT"' EXIT
# Spelled as the build sees it (no trailing slash, "." or ".."), so the check below finds it.
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
cd "$WORK"
WORK_REAL=$(pwd -P)
[ -d sing-box ] || git clone -q --depth 1 --branch v1.14.4 https://github.com/SagerNet/sing-box.git
cd sing-box
# Reset and cleaned only when it is a checkout of its own, not a folder inside some other repository.
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || { echo "$PWD is not a git checkout of its own"; exit 1; }
git reset -q --hard
git clean -qfdx
check_module_layout() {
  [ ! -e vendor ] && [ ! -L vendor ] && [ ! -e go.work ] && [ ! -L go.work ] \
    || { echo "sing-box checkout contains vendor or go.work"; exit 1; }
}
check_module_layout
# Pinned (tools/build-cli.sh and the tests read this line): v1.14.4
PIN=c005f35300ce76427dc285481ec5695f5b179cd2
[ "$(git rev-parse HEAD)" = "$PIN" ] || { echo "sing-box checkout is not v1.14.4"; exit 1; }
# What the engine is built from (the commit and each patch's hash), read again before it is recorded: a patch edited
# while this runs must not be recorded as the one the engine came from.
mkdir -p "$ROOT/Frameworks"
FROM=$("$ROOT/tools/engine-manifest.sh" --provenance)
git apply "$ROOT"/tools/sing-box-*.patch
check_module_layout
# ZERO_AR_DATE: libtool would stamp the archive's symbol table with the time of the build.
export GOTOOLCHAIN=go1.26.10 GOFLAGS=-mod=readonly GOWORK=off GOSUMDB=sum.golang.org \
  GOPROXY=https://proxy.golang.org,direct GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= GONOPROXY= ZERO_AR_DATE=1
# The pinned gomobile and gobind are installed into a folder of this build's own, first on PATH: whatever GOBIN or an older
# copy in GOPATH/bin says, neither can stand in for them (gomobile finds gobind by PATH).
export GOBIN="$OVPN_ROOT/bin"
mkdir -m 700 "$GOBIN"
export PATH="$GOBIN:$PATH"
# sing-openvpn at the version sing-box pins (go.sum checks the download), with unbraid's patches, built in its place.
go mod download github.com/sagernet/sing-openvpn
go mod verify
cp -R "$(go list -m -f '{{.Dir}}' github.com/sagernet/sing-openvpn)" "$OVPN"
chmod -R u+w "$OVPN"
(cd "$OVPN" && git init -q && git apply "$ROOT"/tools/sing-openvpn-*.patch)
go mod edit -replace github.com/sagernet/sing-openvpn="$OVPN"
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.13 github.com/sagernet/gomobile/cmd/gobind@v0.1.13
[ "$(command -v gomobile)" = "$GOBIN/gomobile" ] && [ "$(command -v gobind)" = "$GOBIN/gobind" ] \
  || { echo "gomobile or gobind is not the one just installed"; exit 1; }
rm -rf Libbox.xcframework
gomobile bind -o Libbox.xcframework -target macos -macosversion=26.0 -libname=box -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=1.14.4 -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
  -tags with_gvisor,with_wireguard,with_utls,with_tailscale,ts_omit_logtail,ts_omit_cachenetmap,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird,with_openvpn,grpcnotrace,badlinkname,tfogo_checklinkname0 \
  ./experimental/libbox
# Nothing in the engine may depend on who built it or where: the committed hash must come out of any checkout.
# A static archive records the builder's uid, gid and umask with each member: rewritten without them (libtool -D).
B=Libbox.xcframework/macos-arm64_x86_64/Libbox.framework/Versions/A/Libbox
[ -f "$B" ] && [ "$(find Libbox.xcframework -type f -name Libbox | wc -l)" -eq 1 ] || { echo "unexpected framework layout"; exit 1; }
T=$(mktemp -d "$WORK/libbox.XXXXXX")
trap 'rm -rf "$OVPN_ROOT" "$T"' EXIT
ARCHS=$(lipo -archs "$B")
SLICES=()
for a in $ARCHS; do
  lipo "$B" -thin "$a" -output "$T/$a.a"
  MEMBERS=$(ar -t "$T/$a.a" | grep -v '^__\.SYMDEF')
  [ -z "$(sort <<< "$MEMBERS" | uniq -d)" ] || { echo "$a: archive members with the same name"; exit 1; }
  mkdir "$T/$a"
  (cd "$T/$a" && ar -x "../$a.a" && libtool -static -D -no_warning_for_no_symbols -o "../$a.norm.a" $MEMBERS)
  SLICES+=("$T/$a.norm.a")
done
lipo -create "${SLICES[@]}" -output "$B"
# The one path the engine may name is the fixed one above.
strings -a "$B" | sed 's#/tmp/unbraid-libbox/sing-openvpn##g' > "$T/strings"
# gomobile and go build work in temporary folders (gomobile-work-*, go-build*): a shared /tmp is no exemption.
LEAKS=("$HOME" "$WORK/" "$WORK_REAL/" /Users/ /var/folders/ gomobile-work go-build)
case "${TMPDIR:-/tmp}" in /tmp|/tmp/|/private/tmp|/private/tmp/) ;; *) LEAKS+=("$TMPDIR") ;; esac
for leak in "${LEAKS[@]}"; do
  rc=0; grep -qF -- "$leak" "$T/strings" || rc=$?
  [ "$rc" -eq 1 ] || { [ "$rc" -eq 0 ] && echo "the engine names a builder path ($leak)"; exit 1; }
done
mkdir -p "$ROOT/Frameworks" && rm -rf "$ROOT/Frameworks/Libbox.xcframework"
mv Libbox.xcframework "$ROOT/Frameworks/"
# The Xcode build checks the whole framework and the patches it came from: commit Libbox.sha256 with the change that
# needs the new engine.
[ "$("$ROOT/tools/engine-manifest.sh" --provenance)" = "$FROM" ] || { echo "the patches changed during the build: build again"; exit 1; }
"$ROOT/tools/engine-manifest.sh" --write
"$ROOT/tools/notices.sh"
