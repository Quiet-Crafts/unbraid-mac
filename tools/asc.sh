# Sourced by tools/xc.sh and tools/release.sh, after they set ROOT: the App Store Connect API team key, which lets
# xcodebuild manage signing without an Xcode account login and notarizes releases. ASC_KEY_ID, ASC_ISSUER_ID and
# ASC_KEY_PATH (the .p8 file) come from the environment; any of them the environment doesn't set (an empty value counts
# as set) comes from .secrets/asc.env, which git ignores: this checkout's, or else the main checkout's when this is a
# worktree. That file holds NAME=value lines, optionally quoted, and # comments; it is read as data, never run, so no
# `export` and no $VARIABLES (a leading ~/ is expanded). asc_load sets ASC_READY to 1 when all three are set and the key
# file can be read, else 0.
asc_load() {
  local file="" common line k v n=0 seen=" " given=0
  local assign='^(ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_PATH)=(.*)$' dq='^"(.*)"$' sq="^'(.*)'\$"
  if [ -f "$ROOT/.secrets/asc.env" ]; then
    file="$ROOT/.secrets/asc.env"
  # A worktree's common git folder is the main checkout's .git; anything else (no git, a separate git dir) has no
  # main checkout to look in.
  elif common=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
      && [ "${common##*/}" = .git ] && [ -f "${common%/.git}/.secrets/asc.env" ]; then
    file="${common%/.git}/.secrets/asc.env"
  fi
  if [ -n "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      line=${line%$'\r'}
      case "$line" in '' | '#'*) continue ;; esac
      [[ $line =~ $assign ]] || { echo "$file:$n: error: expected ASC_KEY_ID=, ASC_ISSUER_ID= or ASC_KEY_PATH=" >&2; return 1; }
      k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
      case "$seen" in *" $k "*) echo "$file:$n: error: $k is set twice" >&2; return 1 ;; esac
      seen="$seen$k "
      if [[ $v =~ $dq ]] || [[ $v =~ $sq ]]; then v=${BASH_REMATCH[1]}; fi
      [ -n "${!k+set}" ] || printf -v "$k" '%s' "$v"
    done < "$file"
  fi
  case "${ASC_KEY_PATH:-}" in "~/"*) ASC_KEY_PATH="$HOME/${ASC_KEY_PATH#"~/"}" ;; esac
  ASC_READY=0
  for k in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do [ -z "${!k:-}" ] || given=$((given + 1)); done
  if [ "$given" -eq 3 ] && [ -f "$ASC_KEY_PATH" ] && [ -r "$ASC_KEY_PATH" ]; then
    ASC_READY=1
  elif [ "$given" -gt 0 ]; then
    # Never the values: only which part is missing.
    echo "warning: App Store Connect key incomplete (ASC_KEY_ID, ASC_ISSUER_ID and a readable ASC_KEY_PATH are all needed${file:+; read $file}): not used" >&2
  fi
}
