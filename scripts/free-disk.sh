#!/bin/bash
# The parts of freeing disk space on this Mac that are not a worktree or the build cache
# (#1796). The free-disk-space skill runs them; a person can too. Each is safe to run
# again, and what it removes is made again when it is needed.
#
#   free-disk.sh status                free space now, and how far from the target
#   free-disk.sh chromes [--hours N]   end leaked headless Chromes, then their clones
#   free-disk.sh xcode                 older iOS DeviceSupport builds, unavailable simulators
#   free-disk.sh deriveddata [--dry-run]  Xcode DerivedData of worktrees that are gone
#
# status: the target is 20% of the disk (AGENTS_FREE_TARGET_PCT moves it). It exits 0 when
# free space is at the target or over it, and 1 when it is under.
#
# chromes: a walk's Chrome (Web/test/walk/cdp.mjs) is headless, with a throwaway profile
# under /tmp. One that a walk left keeps running, and a running Chrome keeps the APFS
# clone of the app that macOS made for it (up to 3 GB each) until a restart. This ends
# only a Chrome that is all of these:
#   - the main process (no --type=), started more than N hours ago (default 6);
#   - --headless;
#   - --user-data-dir under /tmp or /private/tmp.
# The person's own Chrome, and the sign-up Chrome (.agents/signups/chrome-profile, not
# headless), are none of these, so they are never ended. Then it removes each clone folder
# no running process has a file open in, and that is more than an hour old.
#
# xcode: Xcode keeps a DeviceSupport folder per device model and OS build (about 6.5 GB
# each). Only the newest build of each model is kept. Simulators whose runtime is gone
# (`simctl delete unavailable`) go too.
#
# deriveddata: Xcode builds each worktree into ~/Library/Developer/Xcode/DerivedData/
# Agents-<hash> (3-4 GB each), not into the worktree, so removing the worktree leaves it
# (#2683). This removes an Agents-* folder only when all of these are true:
#   - its info.plist has a WorkspacePath;
#   - that path is under <main checkout>/.agents/worktrees/;
#   - that path does not exist;
#   - no running xcodebuild names the folder or that worktree.
# A folder with no info.plist, a folder of another project, and Xcode's shared caches
# (ModuleCache.noindex, SDK*) are kept. --dry-run says what it would remove.
set -euo pipefail

die() { echo "free-disk.sh: $*" >&2; exit 1; }

gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }

status() {
	local pct=${AGENTS_FREE_TARGET_PCT:-20} line size avail target
	line=$(df -k "$HOME" | tail -1)
	size=$(echo "$line" | awk '{print $2}')
	avail=$(echo "$line" | awk '{print $4}')
	target=$((size * pct / 100))
	if [ "$avail" -ge "$target" ]; then
		echo "free $(gb "$avail") GB, target $(gb "$target") GB ($pct%): reached"
	else
		echo "free $(gb "$avail") GB, target $(gb "$target") GB ($pct%): $(gb $((target - avail))) GB short"
		return 1
	fi
}

# ps's etime, [[dd-]hh:]mm:ss, in seconds.
seconds() {
	awk -v t="$1" 'BEGIN {
		d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
		n = split(t, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]
		print d * 86400 + s }'
}

chromes() {
	local hours=6
	while [ $# -gt 0 ]; do
		case $1 in
		--hours) hours=$2; shift ;;
		*) die "chromes [--hours N]" ;;
		esac
		shift
	done
	local pid etime cmd ended=0 kept=0
	while read -r pid etime cmd; do
		case $cmd in "/Applications/Google Chrome"*/Contents/MacOS/*) ;; *) continue ;; esac
		case $cmd in *" --type="*) continue ;; esac
		case $cmd in *" --headless"*) ;; *) continue ;; esac
		case $cmd in *" --user-data-dir=/tmp/"* | *" --user-data-dir=/private/tmp/"*) ;; *) continue ;; esac
		if [ "$(seconds "$etime")" -lt $((hours * 3600)) ]; then
			kept=$((kept + 1))
			continue
		fi
		echo "ending Chrome $pid (running $etime): $(echo "$cmd" | grep -o -- '--user-data-dir=[^ ]*')"
		kill "$pid" 2>/dev/null && ended=$((ended + 1)) || true
	done < <(ps -axo pid=,etime=,command=)
	echo "ended $ended headless Chrome(s); $kept younger than $hours hours left running"
	[ "$ended" = 0 ] || sleep 5

	local clones
	clones="$(dirname "$(getconf DARWIN_USER_TEMP_DIR)")/X/com.google.Chrome.code_sign_clone"
	[ -d "$clones" ] || { echo "no Chrome clones"; return 0; }
	local open d k freed=0
	# Every clone any process has a file open in: a running Chrome runs from its own.
	open=$(lsof -nP -Fn 2>/dev/null | sed -n 's#^n.*/com\.google\.Chrome\.code_sign_clone/\(code_sign_clone\.[^/]*\).*#\1#p' | sort -u || true)
	while IFS= read -r d; do
		if printf '%s\n' "$open" | grep -qxF "$(basename "$d")"; then
			echo "kept $(basename "$d"): in use"
			continue
		fi
		k=$(du -sk "$d" | cut -f1)
		echo "removing $(basename "$d") ($(gb "$k") GB apparent)"
		rm -rf -- "$d"
		freed=$((freed + k))
	done < <(find "$clones" -mindepth 1 -maxdepth 1 -type d -name 'code_sign_clone.*' -mmin +60)
	echo "removed clones of $(gb "$freed") GB apparent (clones share blocks, so less is freed)"
}

xcode() {
	local ds="$HOME/Library/Developer/Xcode/iOS DeviceSupport" model d
	if [ -d "$ds" ]; then
		# Names are "<model> <version> (<build>)", such as "iPhone16,2 27.0.1 (24A446)".
		while IFS= read -r model; do
			# All but the newest version of this model, by version order.
			find "$ds" -mindepth 1 -maxdepth 1 -type d -name "$model *" -exec basename {} \; |
				awk '{print $2 "\t" $0}' | sort -t "$(printf '\t')" -k1,1V | cut -f2- | sed '$d' |
				while IFS= read -r d; do
					echo "removing DeviceSupport $d ($(gb "$(du -sk "$ds/$d" | cut -f1)") GB), a newer build is there"
					rm -rf -- "${ds:?}/$d"
				done
		done < <(find "$ds" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | awk '{print $1}' | sort -u)
	fi
	echo "deleting unavailable simulators"
	xcrun simctl delete unavailable || echo "simctl delete unavailable failed: left as it is"
}

deriveddata() {
	local dry=0
	while [ $# -gt 0 ]; do
		case $1 in
		--dry-run) dry=1 ;;
		*) die "deriveddata [--dry-run]" ;;
		esac
		shift
	done
	local dd="$HOME/Library/Developer/Xcode/DerivedData" main
	[ -d "$dd" ] || { echo "no DerivedData"; return 0; }
	main=$(dirname "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)")
	local builds d name ws k freed=0 removed=0 verb=removing
	[ "$dry" = 0 ] || verb="would remove"
	builds=$(pgrep -fl xcodebuild || true)
	while IFS= read -r d; do
		name=$(basename "$d")
		if ! ws=$(plutil -extract WorkspacePath raw "$d/info.plist" 2>/dev/null) || [ -z "$ws" ]; then
			echo "kept $name: no WorkspacePath"
			continue
		fi
		case $ws in
		"$main"/.agents/worktrees/*) ;;
		*) echo "kept $name: $ws is not a worktree of $main"; continue ;;
		esac
		if [ -e "$ws" ]; then
			echo "kept $name: $ws is there"
			continue
		fi
		if [ -n "$builds" ] && printf '%s\n' "$builds" | grep -qF -e "$name" -e "$(dirname "$ws")"; then
			echo "kept $name: an xcodebuild uses it"
			continue
		fi
		k=$(du -sk "$d" | cut -f1)
		echo "$verb $name ($(gb "$k") GB): $ws is gone"
		[ "$dry" = 1 ] || rm -rf -- "$d"
		freed=$((freed + k))
		removed=$((removed + 1))
	done < <(find "$dd" -mindepth 1 -maxdepth 1 -type d -name 'Agents-*')
	if [ "$dry" = 1 ]; then
		echo "would remove $removed folder(s), $(gb "$freed") GB"
	else
		echo "removed $removed folder(s), $(gb "$freed") GB"
	fi
}

case ${1:-} in
status) status ;;
chromes) shift; chromes "$@" ;;
xcode) xcode ;;
deriveddata) shift; deriveddata "$@" ;;
*) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
