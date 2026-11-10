#!/bin/bash
# Replaces the bundled server lists (Resources/Catalog) with gluetun-servers' files at one reviewed commit, and records
# that commit and each file's SHA-256 in manifest.json and in App/Core/CatalogPin.swift, which the app checks the files
# against before reading them. Proton's WireGuard keys are trusted only from these files: review the host and key changes
# it prints before committing. The commit must be on upstream qdm12/gluetun-servers main (checked with `gh`): a commit
# that exists only in a fork is served by the same raw URLs. Usage: tools/update-catalog.sh <40-hex commit>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/Resources/Catalog"
FILES=(protonvpn expressvpn)
COMMIT=${1:-}
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "usage: $0 <full 40-character gluetun-servers commit>" >&2; exit 2; }

# On upstream main: comparing the commit (base) with main (head) says "ahead" or "identical" only for an ancestor of main.
command -v gh >/dev/null || { echo "gh (GitHub CLI) is needed to check the commit is on upstream main" >&2; exit 2; }
CMP=$(gh api "repos/qdm12/gluetun-servers/compare/$COMMIT...main" --jq '.status + " " + (.commits | length | tostring)') \
  || { echo "couldn't compare $COMMIT with qdm12/gluetun-servers main" >&2; exit 1; }
HEAD=$(gh api repos/qdm12/gluetun-servers/commits/main --jq .sha) || { echo "couldn't read qdm12/gluetun-servers main" >&2; exit 1; }
case ${CMP%% *} in
  ahead|identical) echo "$COMMIT is on qdm12/gluetun-servers main (main is $HEAD, ${CMP#* } commits later)" ;;
  *) echo "refused: $COMMIT is not on qdm12/gluetun-servers main (status: ${CMP%% *})" >&2; exit 1 ;;
esac

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for f in "${FILES[@]}"; do
  curl -fsS --proto =https --max-time 60 -o "$TMP/$f.json" \
    "https://raw.githubusercontent.com/qdm12/gluetun-servers/$COMMIT/pkg/servers/$f.json"
  # Only a list the app can read replaces the old one.
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get("servers"), list) and d["servers"], "no servers"' "$TMP/$f.json"
done

mkdir -p "$OUT"
{
  printf '{\n  "source": "https://github.com/qdm12/gluetun-servers",\n  "commit": "%s",\n  "files": {\n' "$COMMIT"
  for i in "${!FILES[@]}"; do
    f=${FILES[$i]}
    sep=$([ "$i" -lt $((${#FILES[@]} - 1)) ] && echo "," || true)
    printf '    "%s.json": "%s"%s\n' "$f" "$(shasum -a 256 "$TMP/$f.json" | cut -d' ' -f1)" "$sep"
  done
  printf '  }\n}\n'
} > "$TMP/manifest.json"
{
  echo "// Written by tools/update-catalog.sh: the gluetun-servers commit of the bundled lists and their SHA-256. Not edited by hand."
  echo "nonisolated extension Catalog {"
  echo "    static let pin = Manifest("
  echo "        commit: \"$COMMIT\","
  echo "        files: ["
  for f in "${FILES[@]}"; do echo "            \"$f.json\": \"$(shasum -a 256 "$TMP/$f.json" | cut -d' ' -f1)\","; done
  echo "        ])"
  echo "}"
} > "$TMP/CatalogPin.swift"

# What a reviewer must look at, by the app's own rules (Catalog.identity, Catalog.validKey, Catalog.Pinned): Proton hosts
# that are new, gone, or have a changed key, and hosts the app will refuse (two keys, or a malformed one).
python3 -I - "$OUT/protonvpn.json" "$TMP/protonvpn.json" <<'PY'
import base64, binascii, json, os, sys
def identity(h):
    h = h.strip().lower()
    if h.endswith("."): h = h[:-1]
    return h or None
def valid(k):
    try: d = base64.b64decode(k, validate=True)
    except (binascii.Error, ValueError): return False
    return len(d) == 32 and base64.b64encode(d).decode() == k
def keys(path):
    if not os.path.exists(path): return {}, set()
    out, doubtful = {}, set()
    for s in json.load(open(path))["servers"]:
        h = identity(s.get("hostname", ""))
        # As Catalog.Pinned: no key is skipped; an empty or malformed one makes the host refused.
        if s.get("vpn") != "wireguard" or not h or s.get("wgpubkey") is None: continue
        k = s["wgpubkey"]
        if not valid(k) or (h in out and out[h] != k): doubtful.add(h)
        out.setdefault(h, k)
    return {h: k for h, k in out.items() if h not in doubtful}, doubtful
(old, _), (new, refused) = keys(sys.argv[1]), keys(sys.argv[2])
added = sorted(set(new) - set(old)); gone = sorted(set(old) - set(new))
changed = sorted(h for h in set(old) & set(new) if old[h] != new[h])
print(f"Proton WireGuard hosts: {len(added)} new, {len(changed)} with a changed key, {len(gone)} gone, {len(refused)} refused")
for label, hosts in (("new", added), ("changed key", changed), ("gone", gone), ("refused (two keys or malformed)", sorted(refused))):
    for h in hosts: print(f"  {label}: {h}")
PY

for f in "${FILES[@]}"; do mv "$TMP/$f.json" "$OUT/$f.json"; done
mv "$TMP/manifest.json" "$OUT/manifest.json"
mv "$TMP/CatalogPin.swift" "$ROOT/App/Core/CatalogPin.swift"
echo "Resources/Catalog and App/Core/CatalogPin.swift now at gluetun-servers $COMMIT"
