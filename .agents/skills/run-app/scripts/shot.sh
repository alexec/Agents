#!/bin/bash
# Screenshot the scratch window, without bringing it to the front.
#
#   shot.sh ROOT OUT.png [--front]
#
# `screencapture -l <window id>` captures a window that is behind the user's own, or on
# another Space (opened behind a full-screen app, #1131), which is what makes looking at
# the app safe while somebody is working. -o drops
# the shadow, -x the shutter sound. --front raises the window first, which steals
# focus: only when nobody is at the keyboard.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:?usage: shot.sh ROOT OUT.png [--front]}"
OUT="${2:?usage: shot.sh ROOT OUT.png [--front]}"
FRONT="${3:-}"

PID="$(pgrep -f "Agents.app/Contents/MacOS/Agents --walk ${ROOT#/tmp/}( |$)" | head -1)"
[ -n "$PID" ] || { echo "no window running on $ROOT" >&2; exit 1; }

if [ "$FRONT" = "--front" ]; then
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
  sleep 0.5
fi

# Biggest window this pid owns — the app's own, not a popover or tooltip — one on screen
# first, else one on another Space. A window on no Space at all captures as nothing.
WID="$(swift "$HERE/ui.swift" windows "$PID" | awk -F'\t' '
  { split($2, d, "x"); area = d[1] * d[2] + ($4 == "on" ? 1e9 : 0); if (area > best) { best = area; id = $1 } }
  END { if (id != "") print id }')"

[ -n "$WID" ] || { echo "no window for pid $PID (no window yet)" >&2; exit 1; }

screencapture -o -x -l "$WID" "$OUT"
echo "$OUT"
