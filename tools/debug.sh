#!/bin/bash
# Sends a command to a running Debug build (see App/DebugHooks.swift) and prints its answer. The command goes in a file
# only this user can read or write; the notification that follows only wakes the app and carries nothing.
d="$HOME/Library/Application Support/unbraid"; f="$d/debug.txt"; rm -f "$f"
mkdir -p "$d" && t=$(mktemp "$d/debug.cmd.XXXXXX") && printf '%s' "$1" > "$t" && mv -f "$t" "$d/debug.cmd" || exit 1
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("app.unbraid.debug"), object: nil, userInfo: nil, deliverImmediately: true)'
for _ in $(seq 1 ${2:-60}); do [ -f "$f" ] && { cat "$f"; exit 0; }; sleep 0.5; done; rm -f "$d/debug.cmd"; echo "no answer (is a Debug build running?)"
