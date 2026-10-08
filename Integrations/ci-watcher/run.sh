#!/bin/sh
# The CI watcher as a LaunchAgent (#383), so it keeps running and comes back after a login.
#
#   run.sh start    write ~/Library/LaunchAgents/com.agents.ci-watcher.plist and load it:
#                   node <here>/server.ts --port 8795, logging to ~/Library/Logs/ci-watcher.log
#   run.sh stop     unload it and delete the plist
#   run.sh status   whether launchd has it, and what /health says
#   run.sh plist    print the plist start would write, and change nothing
#
# It needs Node 26 and a signed-in gh, both found on PATH as start runs.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
label=com.agents.ci-watcher
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/ci-watcher.log"
port=8795
domain="gui/$(id -u)"

need() {
	command -v "$1" >/dev/null 2>&1 || { echo "run.sh: $1 is not on PATH" >&2; exit 1; }
}

xml() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_plist() {
	need node
	need gh
	node=$(command -v node)
	# launchd starts with a bare PATH: give it node's and gh's folders, and the usual ones.
	path="$(dirname "$node"):$(dirname "$(command -v gh)"):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml "$node")</string>
		<string>$(xml "$here/server.ts")</string>
		<string>--port</string>
		<string>$port</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict><key>PATH</key><string>$(xml "$path")</string></dict>
	<key>WorkingDirectory</key><string>$(xml "$here")</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>30</integer>
	<key>StandardOutPath</key><string>$(xml "$log")</string>
	<key>StandardErrorPath</key><string>$(xml "$log")</string>
</dict>
</plist>
EOF
}

case "${1:-}" in
start)
	mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
	launchctl bootout "$domain/$label" 2>/dev/null || true
	write_plist >"$plist"
	launchctl bootstrap "$domain" "$plist"
	echo "started $label on 127.0.0.1:$port (log: $log)"
	;;
stop)
	launchctl bootout "$domain/$label" 2>/dev/null || true
	rm -f "$plist"
	echo "stopped $label"
	;;
status)
	launchctl list | grep ci-watcher || echo "$label is not loaded"
	curl -s --max-time 2 "http://127.0.0.1:$port/health" || echo "nothing answers on 127.0.0.1:$port"
	echo
	;;
plist)
	write_plist
	;;
*)
	echo "usage: run.sh start|stop|status|plist" >&2
	exit 2
	;;
esac
