#!/bin/bash
# The Remote in the walk simulator (#1182): one named iOS simulator, made once and kept,
# booted with no Simulator GUI, the Remote's Debug build in it with its walk socket on.
# `walk.py remote …` then draws and presses it. Never a device, never a throwaway simulator.
#
#   remote.sh up APP [--fake] [-- ARGS…]   boot the walk simulator, install APP (a Debug
#                                          Remote built for the simulator) and launch it with
#                                          -walk (and -fake for the canned daemon)
#   remote.sh udid                         the walk simulator's id (made if missing)
#   remote.sh down                         quit the Remote and shut the simulator down (it is kept)
#
# APP is build/DD-sim/Build/Products/Debug-iphonesimulator/Agents.app after the generic
# simulator build in SKILL.md. AGENTS_WALK_SIM names another device type (iPad: "iPad Pro
# 13-inch (M5) (16GB)"); each device type is its own kept simulator.
set -euo pipefail

NAME="Agents Walk"
TYPE="${AGENTS_WALK_SIM:-iPhone 17 Pro}"
[ "$TYPE" = "iPhone 17 Pro" ] || NAME="Agents Walk ($TYPE)"
BUNDLE=com.alexecollins.agents.remote

die() { echo "remote.sh: $*" >&2; exit 1; }

udid() {
	local id
	id=$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and d.get("isAvailable"):
            print(d["udid"]); sys.exit()' "$NAME")
	if [ -z "$id" ]; then
		# The newest iOS: the Remote's deployment target turns the older ones away.
		local runtime
		runtime=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(ios, key=lambda r: [int(p) for p in r["version"].split(".")])[-1]["identifier"])')
		id=$(xcrun simctl create "$NAME" "$TYPE" "$runtime")
	fi
	echo "$id"
}

case "${1:-}" in
udid)
	udid
	;;
up)
	app="${2:-}"
	[ -d "$app" ] || die "want the Debug Remote's .app, built for the simulator"
	shift 2
	args=(-walk)
	while [ $# -gt 0 ]; do
		case "$1" in
		--fake) args+=(-fake) ;;
		--) shift; args+=("$@"); break ;;
		*) die "unknown $1" ;;
		esac
		shift
	done
	id=$(udid)
	xcrun simctl bootstatus "$id" -b >/dev/null
	xcrun simctl terminate "$id" "$BUNDLE" 2>/dev/null || true
	xcrun simctl install "$id" "$app"
	xcrun simctl launch "$id" "$BUNDLE" "${args[@]}"
	echo "walk: $(dirname "$0")/walk.py remote ping"
	;;
down)
	id=$(udid)
	xcrun simctl terminate "$id" "$BUNDLE" 2>/dev/null || true
	xcrun simctl shutdown "$id" 2>/dev/null || true
	;;
*)
	sed -n '2,15p' "$0"
	exit 2
	;;
esac
