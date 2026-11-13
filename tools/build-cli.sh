#!/bin/bash
# The sing-box command-line tool from the same pinned source, unbraid patches, Go toolchain and build tags as
# tools/build-libbox.sh, for the tests that check generated configs against the engine unbraid ships
# (UNBRAID_SING_BOX, default $WORK/sing-box-cli-mac). Next to it, <cli>.patches records the patches it was built with
# (sing-box's and its OpenVPN module's) and the binary's hash: the tests refuse a CLI built from any other source commit or patch set. The source is v1.14.4 from the
# checkout's git objects with the patches applied in a temporary folder, so whatever state the checkout's working tree
# is in (another build may be patching it) doesn't matter, and nothing in the checkout is written.
set -euo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/Development/unbraid-mac-deps}
SRC=$(cd "$WORK/sing-box" && pwd -P)
# The output's real place, decided before anything else: a plain file (or nothing yet), never inside the checkout.
# Its folder must exist already: creating one first could create it inside the checkout before the check below.
OUT=${1:-$WORK/sing-box-cli-mac}
[ -d "$(dirname "$OUT")" ] || { echo "no folder $(dirname "$OUT")"; exit 1; }
OUTDIR=$(cd "$(dirname "$OUT")" && pwd -P)
OUT="$OUTDIR/$(basename "$OUT")"
case "$OUT/" in "$SRC"/*) echo "the output must be outside $SRC"; exit 1 ;; esac
for f in "$OUT" "$OUT.patches"; do
  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then echo "$f must be a plain file"; exit 1; fi
done
# The commit tools/build-libbox.sh builds the engine from, read from there so the two can't drift apart.
PIN=$(sed -n 's/^PIN=\([0-9a-f]\{40\}\)$/\1/p' "$ROOT/tools/build-libbox.sh")
[[ $PIN =~ ^[0-9a-f]{40}$ ]] || { echo "no PIN in tools/build-libbox.sh"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The patches are read once: the copies are both what is applied and what the stamp names.
mkdir "$TMP/patches"
for p in "$ROOT"/tools/sing-box-*.patch "$ROOT"/tools/sing-openvpn-*.patch; do cp "$p" "$TMP/patches/"; done
PATCHES=("$TMP"/patches/sing-box-*.patch)
[ -f "${PATCHES[0]}" ] || { echo "no tools/sing-box-*.patch"; exit 1; }
OVPN_PATCHES=("$TMP"/patches/sing-openvpn-*.patch)
[ -f "${OVPN_PATCHES[0]}" ] || { echo "no tools/sing-openvpn-*.patch"; exit 1; }

# A private index, object store and work tree; the checkout's objects are only read (alternates). No hooks, split index
# or filesystem monitor, which could write into the checkout.
(
  OBJECTS=$(git -C "$SRC" rev-parse --path-format=absolute --git-path objects)
  GITDIR=$(git -C "$SRC" rev-parse --absolute-git-dir)
  export GIT_DIR="$GITDIR" GIT_WORK_TREE="$TMP/src" GIT_INDEX_FILE="$TMP/index" GIT_OBJECT_DIRECTORY="$TMP/objects" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$OBJECTS"
  mkdir "$TMP/objects" "$TMP/src"
  g() { git -c core.splitIndex=false -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.autocrlf=false "$@"; }
  g cat-file -e "$PIN^{commit}" || { echo "the checkout in $SRC doesn't have sing-box v1.14.4: run tools/build-libbox.sh"; exit 1; }
  g read-tree "$PIN" || exit 1
  g apply --cached "${PATCHES[@]}" || { echo "the patches don't apply to v1.14.4"; exit 1; }
  g checkout-index -a -f || exit 1
)

# The SDK gomobile links the framework against (xcrun --sdk macosx), not whatever cgo would pick by default. go.sum is
# only read (-mod=readonly), and no go.work outside the source takes part. As in tools/build-libbox.sh, sing-openvpn at
# the version sing-box pins (go.sum checks the download) is copied, patched and built in its place, all in the
# temporary folder (the edited go.mod is the temporary source's).
(
  cd "$TMP/src"
  SDK=$(xcrun --sdk macosx --show-sdk-path)
  export GOTOOLCHAIN=go1.26.11 GOFLAGS=-mod=readonly GOWORK=off CGO_ENABLED=1 SDKROOT="$SDK" \
    GOSUMDB=sum.golang.org GOPROXY=https://proxy.golang.org,direct GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= GONOPROXY=
  go mod download github.com/sagernet/sing-openvpn
  go mod verify
  OVPN_SRC=$(go list -m -f '{{.Dir}}' github.com/sagernet/sing-openvpn)
  [ -n "$OVPN_SRC" ] && [ -d "$OVPN_SRC" ] || { echo "no sing-openvpn module"; exit 1; }
  cp -R "$OVPN_SRC" "$TMP/sing-openvpn" && chmod -R u+w "$TMP/sing-openvpn"
  (cd "$TMP/sing-openvpn" && git init -q && git apply "${OVPN_PATCHES[@]}") || { echo "the sing-openvpn patches don't apply"; exit 1; }
  # Relative, so the binary (whose build info names the replacement) doesn't depend on the temporary folder's name.
  go mod edit -replace github.com/sagernet/sing-openvpn=../sing-openvpn
  go build -o "$TMP/sing-box" -trimpath -buildvcs=false \
    -ldflags "-X github.com/sagernet/sing-box/constant.Version=1.14.4 -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
    -tags with_gvisor,with_wireguard,with_utls,with_tailscale,ts_omit_logtail,ts_omit_cachenetmap,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird,with_openvpn,grpcnotrace,badlinkname,tfogo_checklinkname0 \
    ./cmd/sing-box
)
"$TMP/sing-box" version

# The stamp ProviderFixtures.stamp computes: the source commit, each patch (sing-box's and sing-openvpn's) by name
# (byte order) and SHA-256, then the binary's.
sha() {
  local h
  h=$(shasum -a 256 < "$1" | cut -d' ' -f1) || return 1
  [[ $h =~ ^[0-9a-f]{64}$ ]] || { echo "can't hash $1" >&2; return 1; }
  echo "$h"
}
echo "source $PIN" > "$TMP/stamp"
for p in "$TMP"/patches/*.patch; do
  h=$(sha "$p")
  echo "patch $(basename "$p") $h" >> "$TMP/stamp"
done
h=$(sha "$TMP/sing-box")
echo "binary $h" >> "$TMP/stamp"

# Into place from a folder of our own beside the output (renames, never through a link); a binary and stamp that don't
# belong together, should one move fail, fail the tests rather than pass.
PUB=$(mktemp -d "$OUTDIR/.sing-box-cli.XXXXXX")
trap 'rm -rf "$TMP" "$PUB"' EXIT
cp "$TMP/sing-box" "$PUB/cli"
cp "$TMP/stamp" "$PUB/stamp"
mv -fh "$PUB/cli" "$OUT"
mv -fh "$PUB/stamp" "$OUT.patches"
cat "$OUT.patches"
