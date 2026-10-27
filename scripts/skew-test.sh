#!/bin/sh
# Mixed versions, as a person meets them while an update rolls out (#1767, after #1748):
#
#   1. the last release's agentsd joined to this tree's control plane: it is not
#      needsUpdate (unless this tree moved the required set), and machines/list gives its
#      capabilities, so the clients' generated tables can gate what it lacks;
#   2. the last release's control plane with this tree's client: control/status and
#      machines/list answer, with no wrongProtocolVersion (-32008).
#
# Needs Go on the PATH (CI's ubuntu runner). The last release is the newest tag reachable
# from HEAD, or SKEW_TAG; its Go module is taken with git archive, or from SKEW_OLD_SRC (a
# folder holding that tag's Go/), for a run with no git history.
#
#   scripts/skew-test.sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tag=${SKEW_TAG:-$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)}
if [ -z "$tag" ] && [ -z "${SKEW_OLD_SRC:-}" ]; then
	echo "skew-test: no release tag to test against" >&2
	exit 1
fi
work=$(mktemp -d)
pids=""
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null || true; done
	# A host writes its state as it stops: rm only once each has gone, or it races a
	# write and finds a folder not empty.
	for p in $pids; do wait "$p" 2>/dev/null || true; done
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

old=${SKEW_OLD_SRC:-$work/old}
if [ -z "${SKEW_OLD_SRC:-}" ]; then
	mkdir -p "$old"
	git -C "$root" archive "$tag" Go | tar -x -C "$old"
fi
echo "skew-test: $tag against $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo this tree)"

# Each side's agentsd, agents-control and agentsctl. The old tree may have no agentsctl;
# the client is always this tree's.
mkdir -p "$work/new" "$work/oldbin"
(cd "$root/Go" && CGO_ENABLED=0 go build -o "$work/new/" ./cmd/agentsd ./cmd/agents-control ./cmd/agentsctl)
(cd "$old/Go" && CGO_ENABLED=0 go build -o "$work/oldbin/" ./cmd/agentsd ./cmd/agents-control)

# A control plane of `bin`, on `port`, its store and key in `dir`.
start_control() {
	bin=$1 dir=$2 port=$3
	mkdir -p "$dir/store"
	AGENTS_STORE="file://$dir/store/" AGENTS_CONTROL_KEY_FILE="$dir/key" AGENTS_CONTROL_URL="https://127.0.0.1:$port" \
		AGENTS_CONTROL_PROVIDER_HOME="$dir" \
		"$bin/agents-control" serve --port "$port" --self-signed "$dir/tls" --name skew --no-bonjour --no-web \
		>"$dir/control.log" 2>&1 &
	pids="$pids $!"
	i=0
	until AGENTS_STORE="file://$dir/store/" AGENTS_CONTROL_KEY_FILE="$dir/key" \
		"$bin/agents-control" code --host >/dev/null 2>&1; do
		i=$((i + 1))
		if [ "$i" -gt 60 ]; then
			echo "skew-test: the control plane in $dir did not start" >&2
			cat "$dir/control.log" >&2
			exit 1
		fi
		sleep 0.5
	done
}

code_for() {
	bin=$1 dir=$2 kind=$3
	AGENTS_STORE="file://$dir/store/" AGENTS_CONTROL_KEY_FILE="$dir/key" "$bin/agents-control" code "$kind" | head -1
}

# A host of `bin` joined with a host code of the control plane in `dir`.
start_host() {
	bin=$1 dir=$2 code=$3
	mkdir -p "$dir/host"
	HOME="$dir/home" "$bin/agentsd" --root "$dir/host" --serve --control "$code" --host-name "skew host" \
		>"$dir/host.log" 2>&1 &
	pids="$pids $!"
}

# This tree's client, paired with a client code of the control plane in `dir`.
pair() {
	dir=$1 code=$2
	AGENTSCTL="$dir/ctl.json" "$work/new/agentsctl" pair "$code" >/dev/null
}

ctl() {
	dir=$1
	shift
	AGENTSCTL="$dir/ctl.json" "$work/new/agentsctl" "$@"
}

# machines/list's row for the skew host, waiting for it to join.
host_row() {
	dir=$1
	i=0
	while :; do
		row=$(ctl "$dir" hosts 2>/dev/null | tr -d '\n' | grep -o '{[^{}]*"name": *"skew host"[^}]*' || true)
		[ -n "$row" ] && case "$row" in *'"state": "joining"'* | *'"state":"joining"'*) ;; *) echo "$row" && return 0 ;; esac
		i=$((i + 1))
		if [ "$i" -gt 60 ]; then
			echo "skew-test: the host did not join" >&2
			cat "$dir/host.log" "$dir/control.log" >&2
			ctl "$dir" hosts >&2 || true
			exit 1
		fi
		sleep 1
	done
}

failed=0

# 1. The last release's host, this tree's control plane.
one="$work/one"
start_control "$work/new" "$one" 18901
pair "$one" "$(code_for "$work/new" "$one" --client)"
start_host "$work/oldbin" "$one" "$(code_for "$work/new" "$one" --host)"
row=$(host_row "$one")
echo "skew-test: $tag's host on this control plane: $row"
case "$row" in
*needsUpdate*)
	# Allowed only when this tree moved the required set since the tag.
	if git -C "$root" diff --quiet "$tag" -- Go/internal/controlplane/capabilities.go 2>/dev/null; then
		echo "skew-test: FAIL: $tag's host is needsUpdate, and the required set did not move" >&2
		failed=1
	else
		echo "skew-test: needsUpdate, and this tree moved the required set: allowed"
	fi
	;;
esac
# What the clients' generated tables hide for it: this tree's capabilities it lacks.
# HostCapabilities only: the control plane's own (machines/1, control/1) are never a host's.
lacks=$(sed -n '/^var HostCapabilities/,/^}/p' "$root/Go/wire/capabilities_gen.go" | grep -o ': *"[a-z.-]*/[0-9]*"' |
	grep -o '"[^"]*"' | sort -u | while read -r cap; do
	case "$row" in *"$cap"*) ;; *) printf '%s ' "$cap" ;; esac
done)
echo "skew-test: what the clients hide for $tag's host: ${lacks:-nothing}"
case "$row" in
*'"capabilities"'*) ;;
*)
	echo "skew-test: FAIL: machines/list gives no capabilities for $tag's host" >&2
	failed=1
	;;
esac

# 2. The last release's control plane, this tree's client.
two="$work/two"
start_control "$work/oldbin" "$two" 18902
if ! pair "$two" "$(code_for "$work/oldbin" "$two" --client)"; then
	echo "skew-test: FAIL: this client could not pair with $tag's control plane" >&2
	failed=1
elif ! out=$(ctl "$two" call control/status 2>&1); then
	echo "skew-test: FAIL: control/status from $tag's control plane: $out" >&2
	failed=1
else
	case "$out" in
	*-32008*)
		echo "skew-test: FAIL: $tag's control plane refused this client's version: $out" >&2
		failed=1
		;;
	*) echo "skew-test: $tag's control plane answers this client" ;;
	esac
fi

exit "$failed"
