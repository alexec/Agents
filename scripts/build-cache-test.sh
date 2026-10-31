#!/bin/bash
# Tests scripts/build-cache.sh prune (#2346) on a fake cache tree in a temporary folder,
# never the real cache: over its bound, the cache is cut back to it, the oldest used
# folders first, the newest kept, and never a folder a running build uses.
#
#   scripts/build-cache-test.sh
#
# Run by scripts/lint.sh's checks, so on the Mac and on Linux.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
sleeper=
trap '[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null || true; rm -rf "$tmp"' EXIT
failed=0

# A time N hours ago, for touch -t (BSD date, then GNU date).
ago() {
	local t=$(($(date +%s) - $1 * 3600))
	date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$t" +%Y%m%d%H%M.%S
}

# A fake cache: five Swift folders of 1 MB each, used 72, 48, 24, 2 and 1 hours ago.
fake() {
	local c=$tmp/cache d
	rm -rf "$c"
	for d in checkouts/old packages swiftpm cas checkouts/new; do
		mkdir -p "$c/$d"
		dd if=/dev/zero of="$c/$d/blob" bs=1024 count=1024 2>/dev/null
	done
	touch -t "$(ago 72)" "$c/checkouts/old"
	touch -t "$(ago 48)" "$c/packages"
	touch -t "$(ago 24)" "$c/swiftpm"
	touch -t "$(ago 2)" "$c/cas"
	touch -t "$(ago 1)" "$c/checkouts/new"
	echo "$c"
}

# Prune the fake cache to 3.5 MB, with no Go bound in the way and no real build seen.
prune() {
	AGENTS_BUILD_CACHE=$1 AGENTS_BUILD_CACHE_PROCS=${2:-no-such-build-2346} \
		"$here/build-cache.sh" prune --max-gb 0.0044 --go-max-gb 0.0010 >"$tmp/out" 2>&1 ||
		{ echo "build-cache-test: prune failed:"; cat "$tmp/out"; failed=1; }
}

expect() { # what cache/<folder> gone|kept
	local c=$1 d=$2 want=$3 got=kept
	[ -e "$c/$d" ] || got=gone
	if [ "$got" != "$want" ]; then
		echo "build-cache-test: $4: $d is $got, expected $want"
		sed 's/^/  /' "$tmp/out"
		failed=1
	fi
}

# 1. Over the bound: the two oldest go, and the cut stops at the bound.
c=$(fake)
prune "$c"
for d in checkouts/old packages; do expect "$c" "$d" gone "oldest first"; done
for d in swiftpm cas checkouts/new; do expect "$c" "$d" kept "oldest first"; done
grep -q "freed" "$tmp/out" || { echo "build-cache-test: prune does not say how much it freed"; failed=1; }

# 2. A running build named packages in in-use/<pid>: it stays, and the next oldest goes.
c=$(fake)
sleep 300 &
sleeper=$!
disown "$sleeper"
mkdir -p "$c/in-use"
echo "$c/packages" >"$c/in-use/$sleeper"
echo "$c/swiftpm" >"$c/in-use/999999" # a build that ended: its marker goes
prune "$c"
expect "$c" packages kept "in use"
for d in checkouts/old swiftpm; do expect "$c" "$d" gone "in use"; done
for d in cas checkouts/new; do expect "$c" "$d" kept "in use"; done
expect "$c" in-use/999999 gone "ended build"

# 3. A build runs that named no folders (an older script): nothing goes.
c=$(fake)
prune "$c" "sleep 300"
for d in checkouts/old packages swiftpm cas checkouts/new; do expect "$c" "$d" kept "unknown build"; done

[ "$failed" = 0 ] && echo "build-cache-test: ok"
exit "$failed"
