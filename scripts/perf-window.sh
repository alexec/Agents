#!/bin/bash
# Time the window on a scratch root, against budgets (073): cold start to the first frame
# and to the first list, and chat opens, read from the window's own `perf` log lines
# (App/Sources/Perf.swift). Exits 1 if a median is over its budget.
#
#   scripts/perf-window.sh SLUG [FOLDER_A FOLDER_B CHAT_1 CHAT_2 [CHAT…]]
#
# SLUG is a root started by the run-app skill's launch.sh (/tmp/run-SLUG), its window
# already paired once. The window is quit by its pid and opened again behind whatever is
# in front (`open -g`); nothing is clicked or typed. Chat opens select sidebar rows through
# the window's walk socket (walk.py, #1172), in its own process, so a locked screen does not
# stop them (#5427): the AX server shows only the menu bar then. The walk socket is in a
# Debug build only; with CONFIG=Live only the cold start is timed.
# FOLDER_* are text in the two folders' rows, unfolded first (e.g. "/tmp/run-SLUG/work").
# CHAT_* are sessions' titles, opened in turn three times; give sessions in both folders, so
# some opens change the folder too. A folder is picked only by opening one of its sessions
# since the sidebar's folder rows became headings, so that is timed as a chat open: the
# "folder switch" figure, 150 ms in 073 for drawing a project's list, was retired (#5427).
set -euo pipefail
SLUG=${1:?usage: perf-window.sh SLUG [FOLDER_A FOLDER_B CHAT_1 CHAT_2 [CHAT…]]}
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# CONFIG=Live times ship-app's optimised build (#220), launched with launch.sh --config Live.
APP="$REPO/build/DD/Build/Products/${CONFIG:-Debug}/Agent Loops.app"
walk() { python3 "$REPO/.agents/skills/run-app/scripts/walk.py" "/tmp/run-$SLUG" "$@"; }
WORK="${TMPDIR:-/tmp}/perf-window-$SLUG"
mkdir -p "$WORK"
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

# Budgets in ms, for a Debug build on this Mac, from scripts/perf-budgets.json (#4784).
budget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["night"]["mac"][sys.argv[2]])' "$REPO/scripts/perf-budgets.json" "$1"; }
B_WINDOW=$(budget "cold start: first frame"); B_LIST=$(budget "cold start: first list")
B_CHAT=$(budget "chat open")

pid_of() { pgrep -f "(Agent Loops|Agents)\.app/Contents/MacOS/Agents( Host)? --walk run-$SLUG( |$)" | head -1 || true; }
# perf_lines PID --last 1m | --start "<date>"
perf_lines() { local pid=$1; shift; /usr/bin/log show "$@" --style compact \
  --predicate "processID == $pid AND category == \"perf\"" 2>/dev/null | grep -o 'perf .*' || true; }
median() { sort -n | awk '{a[NR]=$1} END {if (NR==0) print "-"; else print a[int((NR+1)/2)]}'; }

windows=(); lists=()
for _ in $(seq 1 "$RUNS"); do
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
    first=$(perf_lines "$pid" --last 1m | awk '/first-list/ {print $3; exit}'); [ -n "$first" ] && break; sleep 0.2
  done
  lists+=("${first:--1}")
done
pid=$(pid_of)

chats=""; why="no sidebar row reached by the walk socket"
if [ $# -ge 5 ] && ! walk ping >/dev/null 2>&1; then
  why="the window's walk socket did not answer (a Debug build with --walk has it)"
elif [ $# -ge 5 ]; then
  sleep 2
  walk press "=Not now" >/dev/null 2>&1 || true
  walk unfold "$2" >/dev/null 2>&1 || true
  walk unfold "$3" >/dev/null 2>&1 || true
  sleep 1
  for _ in $(seq 1 3); do
    for chat in "${@:4}"; do
      walk select "=$chat" >/dev/null 2>&1 || true; sleep 2.5
    done
  done
  chats=$(perf_lines "$pid" --last 2m | awk '/chat-open [0-9]/ {print $3}')
fi

over=0
row() { # name, values, budget
  local m; m=$(printf '%s\n' $2 | grep -v '^-1$' | median)
  local flag="ok  "; if [ "$m" = "-" ] || [ "$m" -gt "$3" ]; then flag="OVER"; over=1; fi
  printf '%s %-34s median %6s ms  (all: %s; budget %s)\n' "$flag" "$1" "$m" "$(echo $2 | tr '\n' ' ')" "$3"
}
row "cold start: first frame" "${windows[*]}" $B_WINDOW
row "cold start: first list" "${lists[*]}" $B_LIST
# A row the walk did not reach is said, not left out (#4784).
if [ -n "$chats" ]; then row "chat open" "$chats" $B_CHAT
elif [ $# -ge 5 ]; then echo "SKIP chat open: not measured ($why)"; fi
exit $over
