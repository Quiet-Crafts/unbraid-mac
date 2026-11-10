#!/bin/bash
# The complete source of a release (GPL-3.0 §6), published next to its DMG as one archive: unbraid at the release
# commit; the engine's source, sing-box v1.14.4 with unbraid's patches applied and its patched OpenVPN module; every Go
# module the engine and its bindings are built from, as a module proxy folder; the gomobile tools that generate the
# bindings; and BUILDING.txt, which names the toolchain and gives the commands. Usage: tools/source-archive.sh <commit>
# <out.tar.gz>. The pins, patches and build recipe are the commit's own; sing-box's git objects come from $WORK/sing-box,
# which is only read, as tools/build-cli.sh does. tools/release.sh also passes LOCAL_XCCONFIG, the Config/Local.xcconfig
# the release was built with (empty: none), and RELEASE_BUILD, its build number.
set -euo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -eq 2 ] || { echo "usage: $0 <commit> <out.tar.gz>"; exit 1; }
COMMIT=$(git -C "$ROOT" rev-parse --verify --quiet "$1^{commit}") || { echo "no commit $1"; exit 1; }
[ -d "$(dirname "$2")" ] || { echo "no folder $(dirname "$2")"; exit 1; }
LOCAL_XCCONFIG=${LOCAL_XCCONFIG:-} RELEASE_BUILD=${RELEASE_BUILD:-}
[ -z "$LOCAL_XCCONFIG" ] || { [ ! -L "$LOCAL_XCCONFIG" ] && [ -f "$LOCAL_XCCONFIG" ] && [ -r "$LOCAL_XCCONFIG" ]; } \
  || { echo "LOCAL_XCCONFIG must name a readable file, not a link"; exit 1; }
[ -z "$RELEASE_BUILD" ] || [[ $RELEASE_BUILD =~ ^[0-9]{12}$ ]] || { echo "RELEASE_BUILD must be 12 digits"; exit 1; }
OUT="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
NAME=$(basename "$OUT" .tar.gz)
WORK=${WORK:-$HOME/Development/unbraid-mac-deps}
SRC=$(cd "$WORK/sing-box" 2>/dev/null && pwd -P) || { echo "no sing-box checkout in $WORK: run tools/build-libbox.sh"; exit 1; }
# A module cache's files are read-only: made writable again so the folder can be removed.
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
D="$T/$NAME"
mkdir -p "$D"

# unbraid as committed: the patches, pins and build recipe below are read from here. Through a file, not a pipe: bsdtar
# stops at the end-of-archive marker while git may still be writing padding, and pipefail then fails on git's SIGPIPE.
git -C "$ROOT" archive --format=tar --prefix=unbraid/ -o "$T/unbraid.tar" "$COMMIT"
tar -x -f "$T/unbraid.tar" -C "$D"
rm -f "$T/unbraid.tar"
U="$D/unbraid"
LOCAL_NOTE=
if [ -n "$LOCAL_XCCONFIG" ]; then
  [ ! -e "$U/Config/Local.xcconfig" ] && [ ! -L "$U/Config/Local.xcconfig" ] || { echo "the commit has a Config/Local.xcconfig of its own"; exit 1; }
  cp "$LOCAL_XCCONFIG" "$U/Config/Local.xcconfig"
  LOCAL_NOTE="
                unbraid/Config/Local.xcconfig is not in the commit: it is the local signing override (team, bundle
                IDs, profiles) the release was built with, SHA-256 $(shasum -a 256 < "$U/Config/Local.xcconfig" | cut -d' ' -f1)."
fi
PIN=$(sed -n 's/^PIN=\([0-9a-f]\{40\}\)$/\1/p' "$U/tools/build-libbox.sh")
GO=$(sed -n 's/.*GOTOOLCHAIN=\(go[0-9.]*\).*/\1/p' "$U/tools/build-libbox.sh" | head -1)
GOMOBILE=$(sed -n 's#.*github.com/sagernet/gomobile/cmd/gomobile@\(v[0-9.]*\).*#\1#p' "$U/tools/build-libbox.sh" | head -1)
TAGS=$(sed -n 's/.*-tags \([^ ]*\).*/\1/p' "$U/tools/build-libbox.sh")
BIND_CMD=$(sed -n '/^gomobile bind /,/\.\/experimental\/libbox$/p' "$U/tools/build-libbox.sh")
[[ $PIN =~ ^[0-9a-f]{40}$ ]] && [ -n "$GO" ] && [ -n "$GOMOBILE" ] && [ -n "$TAGS" ] && [ -n "$BIND_CMD" ] \
  || { echo "can't read the pin, Go, gomobile, tags or bind command from tools/build-libbox.sh"; exit 1; }
PATCHES=("$U"/tools/sing-box-*.patch) OVPN_PATCHES=("$U"/tools/sing-openvpn-*.patch)
[ -f "${PATCHES[0]}" ] && [ -f "${OVPN_PATCHES[0]}" ] || { echo "no engine patches in tools/"; exit 1; }

# sing-box at the pinned commit with the patches, through a private index and object store (the checkout's are read).
(
  OBJECTS=$(git -C "$SRC" rev-parse --path-format=absolute --git-path objects)
  GITDIR=$(git -C "$SRC" rev-parse --absolute-git-dir)
  export GIT_DIR="$GITDIR" GIT_WORK_TREE="$D/sing-box" GIT_INDEX_FILE="$T/index" GIT_OBJECT_DIRECTORY="$T/objects" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$OBJECTS"
  mkdir "$T/objects" "$D/sing-box"
  g() { git -c core.splitIndex=false -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.autocrlf=false "$@"; }
  g cat-file -e "$PIN^{commit}" || { echo "the checkout in $SRC doesn't have sing-box $PIN: run tools/build-libbox.sh"; exit 1; }
  g read-tree "$PIN" && g apply --cached "${PATCHES[@]}" && g checkout-index -a -f
)

# The pinned toolchain, run directly so the empty module cache below doesn't fetch it again.
export GOWORK=off GOFLAGS=-mod=mod GOSUMDB=sum.golang.org GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= GONOPROXY=
GOCMD="$(GOTOOLCHAIN=$GO go env GOROOT)/bin/go"
[ -x "$GOCMD" ] || { echo "no Go toolchain $GO"; exit 1; }
export GOTOOLCHAIN=local
# An empty module cache of its own, filled from this Mac's cache first: every module below is unpacked afresh from a
# download go.sum (or the checksum database) vouches for, never copied from a folder that could have been edited since,
# and what it ends up holding is exactly what the build needs (goproxy/ below).
PROXY="file://$("$GOCMD" env GOMODCACHE)/cache/download,$("$GOCMD" env GOPROXY)"
export GOMODCACHE="$T/modcache" GOPROXY="$PROXY"
cd "$D/sing-box"
# The OpenVPN module at the version sing-box pins, patched, in its place.
"$GOCMD" mod download github.com/sagernet/sing-openvpn
cp -R "$("$GOCMD" list -m -f '{{.Dir}}' github.com/sagernet/sing-openvpn)" "$D/sing-openvpn"
chmod -R u+w "$D/sing-openvpn"
(cd "$D/sing-openvpn" && git init -q && git apply "${OVPN_PATCHES[@]}" && rm -rf .git)
"$GOCMD" mod edit -replace github.com/sagernet/sing-openvpn=../sing-openvpn
# The gomobile and gobind tools' source.
dir=$("$GOCMD" mod download -json github.com/sagernet/gomobile@"$GOMOBILE" | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$/\1/p')
[ -d "$dir" ] || { echo "no gomobile $GOMOBILE"; exit 1; }
cp -R "$dir" "$D/gomobile-$GOMOBILE"
chmod -R u+w "$D/gomobile-$GOMOBILE"
BIND=$("$GOCMD" list -m -f '{{.Version}}' github.com/sagernet/gomobile)

# Every Go module the build needs, as a module proxy folder (goproxy/): loading the engine's packages for both
# architectures, the bindings' runtime and the gomobile tools fetches exactly those into the empty cache. Modules
# sing-box uses only with other build tags (prebuilt Cronet libraries among them, over a gigabyte) stay out.
(
  for arch in arm64 amd64; do
    GOOS=darwin GOARCH=$arch CGO_ENABLED=1 "$GOCMD" list -deps -tags "$TAGS" ./experimental/libbox github.com/sagernet/gomobile/bind/seq >/dev/null
  done
  cd "$D/gomobile-$GOMOBILE" && "$GOCMD" list -deps ./cmd/gomobile ./cmd/gobind >/dev/null
)
cp -R "$T/modcache/cache/download" "$D/goproxy"
rm -rf "$D/goproxy/sumdb"
find "$D/goproxy" \( -name '*.lock' -o -name '*.partial' \) -delete

XCODE=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
cat > "$D/BUILDING.txt" <<EOF
unbraid for Mac: complete source of $NAME
unbraid commit $COMMIT, engine sing-box $PIN (v1.14.4) with unbraid's patches.

unbraid/        The app, its tunnel extension and widgets (GPL-3.0-or-later), at the release commit, with the build
                scripts (tools/) and the engine patches (tools/*.patch).$LOCAL_NOTE
sing-box/       sing-box v1.14.4 with unbraid/tools/sing-box-*.patch applied. Its go.mod replaces the OpenVPN module with
                ../sing-openvpn.
sing-openvpn/   sing-box's OpenVPN module at the version sing-box pins, with unbraid/tools/sing-openvpn-*.patch applied.
goproxy/        Every other Go module the engine, its bindings (gomobile $BIND) and the gomobile tools are built from, as
                a Go module proxy folder: the module zips, checked against the go.sum files when they are used.
gomobile-$GOMOBILE/ The gomobile and gobind tools that generate the engine's Objective-C bindings.

The release was built with $XCODE (macOS SDK $(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "?")),
Go ${GO#go}, gomobile $GOMOBILE and XcodeGen. The licences of everything here are in unbraid/Resources/notices.txt.

1. The engine, Libbox.xcframework, with no network needed. Install Go ${GO#go} first (https://go.dev/dl/), its bin folder
   first on PATH: \`GOTOOLCHAIN=local go version\` must say $GO. goproxy/ holds the Go modules but no Go toolchains, so
   another Go can't download this one from there. The Go standard library and runtime in the engine are that release's;
   their source is part of the Go download.
     export GOTOOLCHAIN=$GO GOPROXY=file://\$PWD/goproxy GOFLAGS=-mod=mod GOWORK=off ZERO_AR_DATE=1
     (cd gomobile-$GOMOBILE && go install ./cmd/gomobile ./cmd/gobind)
     export PATH=\$(go env GOPATH)/bin:\$PATH
     cd sing-box
$(sed 's/^/     /' <<< "$BIND_CMD")
   unbraid/tools/build-libbox.sh is the same build from a fresh clone; it also builds the OpenVPN module from a fixed
   folder and normalises the static library, so its hash matches unbraid/Frameworks/Libbox.sha256 with the same Xcode.
2. The app: move Libbox.xcframework into unbraid/Frameworks/, then in unbraid/
     tools/engine-manifest.sh --write
     xcodegen && xcodebuild -project unbraid.xcodeproj -scheme unbraid -configuration Release build${RELEASE_BUILD:+ CURRENT_PROJECT_VERSION=$RELEASE_BUILD}
   The first command records your engine in Frameworks/Libbox.sha256, which the build checks: built as in step 1 its
   hash differs from the release's (the OpenVPN module's folder is named in it, and step 1 skips the normalisation).
   unbraid/README.md (Build) explains signing with your own team.
EOF

# Only the files: no macOS metadata, extended attributes or owners in the archive.
rm -f "$OUT"
(cd "$T" && COPYFILE_DISABLE=1 tar -c -z --no-mac-metadata --no-xattrs --no-fflags --uid 0 --gid 0 --uname root --gname wheel -f "$OUT" "$NAME")
echo "$OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
