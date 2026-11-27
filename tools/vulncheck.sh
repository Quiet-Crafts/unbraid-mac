#!/bin/bash
# Scan the same patched engine source and build tags as the CLI and framework builds.
set -euo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/Development/unbraid-mac-deps}
SRC=$(cd "$WORK/sing-box" && pwd -P)
# The commit tools/build-libbox.sh builds the engine from, read from there so the two can't drift apart.
PIN=$(sed -n 's/^PIN=\([0-9a-f]\{40\}\)$/\1/p' "$ROOT/tools/build-libbox.sh")
[[ $PIN =~ ^[0-9a-f]{40}$ ]] || { echo "no PIN in tools/build-libbox.sh"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The patches are read once: the copies are both what is applied and what the stamp names.
mkdir "$TMP/patches"
for p in "$ROOT"/tools/sing-box-*.patch "$ROOT"/tools/sing-openvpn-*.patch; do cp "$p" "$TMP/patches/"; done
for p in "$ROOT"/tools/sing-tun-*.patch "$ROOT"/tools/gvisor-*.patch; do if [ -f "$p" ]; then cp "$p" "$TMP/patches/"; fi; done
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
# temporary folder (the edited go.mod is the temporary source's); so are sing-tun and gVisor when they have patches.
(
  cd "$TMP/src"
  SDK=$(xcrun --sdk macosx --show-sdk-path)
  export GOTOOLCHAIN=go1.26.11 GOFLAGS=-mod=readonly GOWORK=off CGO_ENABLED=1 GOOS=darwin SDKROOT="$SDK" \
    GOSUMDB=sum.golang.org GOPROXY=https://proxy.golang.org,direct GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= GONOPROXY=
  go mod download github.com/sagernet/sing-openvpn
  go mod verify
  OVPN_SRC=$(go list -m -f '{{.Dir}}' github.com/sagernet/sing-openvpn)
  [ -n "$OVPN_SRC" ] && [ -d "$OVPN_SRC" ] || { echo "no sing-openvpn module"; exit 1; }
  cp -R "$OVPN_SRC" "$TMP/sing-openvpn" && chmod -R u+w "$TMP/sing-openvpn"
  (cd "$TMP/sing-openvpn" && git init -q && git apply "${OVPN_PATCHES[@]}") || { echo "the sing-openvpn patches don't apply"; exit 1; }
  # Relative, so the binary (whose build info names the replacement) doesn't depend on the temporary folder's name.
  go mod edit -replace github.com/sagernet/sing-openvpn=../sing-openvpn
  scan() {
    go run golang.org/x/vuln/cmd/govulncheck@v1.1.4 -tags with_gvisor,with_wireguard,with_utls,with_tailscale,ts_omit_logtail,ts_omit_cachenetmap,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird,with_openvpn,grpcnotrace,badlinkname,tfogo_checklinkname0 ./experimental/libbox ./cmd/sing-box
  }
  # govulncheck matches advisories by module version, and a module replaced by a local folder has none: so with sing-tun
  # or gVisor patches, the versions sing-box pins are checked first, then the patched source below. The pins are checked
  # by module, not by call: the patched engine uses API only their patches add, so it can't be built against them.
  # Any advisory for either pinned module fails the check, reachable or not.
  MODULE_PATCHES=("$TMP"/patches/sing-tun-*.patch "$TMP"/patches/gvisor-*.patch)
  if [ -f "${MODULE_PATCHES[0]}" ] || [ -f "${MODULE_PATCHES[${#MODULE_PATCHES[@]}-1]}" ]; then
    echo "== sing-tun and gVisor as sing-box pins them"
    go run golang.org/x/vuln/cmd/govulncheck@v1.1.4 -scan module -format json > "$TMP/pins.json"
    python3 -I - "$TMP/pins.json" <<'PY' || exit 1
import json, sys
text, at, dec, hits, seen = open(sys.argv[1]).read(), 0, json.JSONDecoder(), set(), 0
while True:
    while at < len(text) and text[at].isspace(): at += 1
    if at >= len(text): break
    obj, at = dec.raw_decode(text, at)
    seen += "finding" in obj
    for frame in (obj.get("finding") or {}).get("trace") or []:
        if frame.get("module") in ("github.com/sagernet/sing-tun", "github.com/sagernet/gvisor"):
            hits.add(f'{obj["finding"]["osv"]} in {frame["module"]} {frame.get("version", "")}')
for h in sorted(hits): print("advisory:", h)
print(f"{seen} module findings read; " + ("no advisories for the pinned sing-tun or gVisor" if not hits else "the pinned sing-tun or gVisor has advisories"))
sys.exit(1 if hits else 0)
PY
    echo "== with the sing-tun and gVisor patches"
  fi
  for m in sing-tun gvisor; do
    P=("$TMP"/patches/"$m"-*.patch)
    [ -f "${P[0]}" ] || continue
    go mod download github.com/sagernet/"$m"
    go mod verify
    M=$(go list -m -f '{{.Dir}}' github.com/sagernet/"$m")
    [ -n "$M" ] && [ -d "$M" ] || { echo "no $m module"; exit 1; }
    cp -R "$M" "$TMP/$m" && chmod -R u+w "$TMP/$m"
    (cd "$TMP/$m" && git init -q && for p in "${P[@]}"; do git apply "$p" && git apply --reverse --check "$p" || exit 1; done) \
      || { echo "the $m patches don't apply"; exit 1; }
    go mod edit -replace github.com/sagernet/"$m"=../"$m"
  done
  scan
)
