#!/bin/bash
# Time the window on a scratch root, against budgets (073): cold start to the first frame
# and to the first list, project switches and chat opens, read from the window's own
# `perf` log lines (App/Sources/Perf.swift). Exits 1 if a median is over its budget.
#
#   scripts/perf-window.sh SLUG [PROJECT_A PROJECT_B CHAT_A CHAT_B]
#
# SLUG is a root started by the run-app skill's launch.sh (/tmp/run-SLUG), its window
# already paired once. The window is quit by its pid and opened again behind whatever is
# in front (`open -g`); nothing is clicked or typed. Project switches and chat opens
# select sidebar rows by accessibility (AXSelected), so the process running this needs
# Accessibility permission; without it only the cold start is timed. PROJECT_* and CHAT_*
# are text in the rows' labels, e.g. "work, 41" and "Long chat 100k".
set -euo pipefail
SLUG=${1:?usage: perf-window.sh SLUG [PROJECT_A PROJECT_B CHAT_A CHAT_B]}
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# CONFIG=Live times ship-app's optimised build (#220), launched with launch.sh --config Live.
APP="$REPO/build/DD/Build/Products/${CONFIG:-Debug}/Agents.app"
UI_SRC="$REPO/.agents/skills/run-app/scripts/ui.swift"
WORK="${TMPDIR:-/tmp}/perf-window-$SLUG"
mkdir -p "$WORK"
[ -x "$WORK/ui" ] || swiftc -O -o "$WORK/ui" "$UI_SRC" 2>/dev/null
# winwait PID T0: milliseconds from T0 until PID has a window on screen.
if [ ! -x "$WORK/winwait" ]; then
  cat >"$WORK/winwait.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let t0 = Double(CommandLine.arguments[2])!
while Date().timeIntervalSince1970 - t0 < 30 {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        if let b = w[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) > 300,
           (w[kCGWindowLayer as String] as? Int) == 0 {
            print(String(format: "%.0f", (Date().timeIntervalSince1970 - t0) * 1000), w[kCGWindowNumber as String]!)
            exit(0)
        }
    }
    usleep(5000)
}
print("-1 0")
SWIFT
  swiftc -O -o "$WORK/winwait" "$WORK/winwait.swift" 2>/dev/null
fi
RUNS=${RUNS:-3}

# Budgets in ms, for a Debug build on this Mac.
B_WINDOW=1500; B_LIST=2000; B_SWITCH=150; B_CHAT=500

pid_of() { pgrep -f "Agents.app/Contents/MacOS/Agents --walk run-$SLUG( |$)" | head -1 || true; }
perf_lines() { /usr/bin/log show --last "${2:-2m}" --style compact \
  --predicate "processID == $1 AND category == \"perf\"" 2>/dev/null | grep -o 'perf .*' || true; }
median() { sort -n | awk '{a[NR]=$1} END {if (NR==0) print "-"; else print a[int((NR+1)/2)]}'; }

windows=(); lists=()
for run in $(seq 1 "$RUNS"); do
  old=$(pid_of); [ -n "$old" ] && kill "$old" && while ps -p "$old" >/dev/null; do sleep 0.05; done
  t0=$(python3 -c 'import time; print(time.time())')
  env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 PATH=/usr/bin:/bin \
    open -n -g "$APP" --args --walk "run-$SLUG" -ApplePersistenceIgnoreState YES
  pid=""; for _ in $(seq 1 400); do pid=$(pid_of); [ -n "$pid" ] && break; sleep 0.01; done
  # The first on-screen window of that pid, timed from the open.
  ms=$("$WORK/winwait" "$pid" "$t0" | cut -d" " -f1) || ms=-1
  windows+=("$ms")
  first=""
  for _ in $(seq 1 100); do
    first=$(perf_lines "$pid" 1m | awk '/first-list/ {print $3; exit}'); [ -n "$first" ] && break; sleep 0.2
  done
  lists+=("${first:--1}")
done
pid=$(pid_of)

switches=""; chats=""
if [ $# -ge 5 ]; then
  sleep 2
  "$WORK/ui" press "$pid" "Not now" >/dev/null 2>&1 || true
  for _ in $(seq 1 5); do
    "$WORK/ui" select "$pid" "$2" >/dev/null; sleep 1.2
    "$WORK/ui" select "$pid" "$3" >/dev/null; sleep 1.2
  done
  "$WORK/ui" select "$pid" "$2" >/dev/null; sleep 1.2
  for _ in $(seq 1 3); do
    "$WORK/ui" select "$pid" "$4" >/dev/null; sleep 2.5
    "$WORK/ui" select "$pid" "$5" >/dev/null; sleep 2.5
  done
  switches=$(perf_lines "$pid" 2m | awk '/project-switch/ {print $3}')
  chats=$(perf_lines "$pid" 2m | awk '/chat-open/ {print $3}')
fi

over=0
row() { # name, values, budget
  local m; m=$(printf '%s\n' $2 | grep -v '^-1$' | median)
  local flag="ok  "; if [ "$m" = "-" ] || [ "$m" -gt "$3" ]; then flag="OVER"; over=1; fi
  printf '%s %-34s median %6s ms  (all: %s; budget %s)\n' "$flag" "$1" "$m" "$(echo $2 | tr '\n' ' ')" "$3"
}
row "cold start: first frame" "${windows[*]}" $B_WINDOW
row "cold start: first list" "${lists[*]}" $B_LIST
[ -n "$switches" ] && row "project switch" "$switches" $B_SWITCH
[ -n "$chats" ] && row "chat open" "$chats" $B_CHAT
exit $over
