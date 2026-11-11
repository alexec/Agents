#!/bin/bash
# The parts of freeing disk space on this Mac that are not a worktree or the build cache
# (#1796). The free-disk-space skill runs them; a person can too. Each is safe to run
# again, and what it removes is made again when it is needed.
#
#   free-disk.sh status                free space now, and how far from the target
#   free-disk.sh chromes [--hours N]   end leaked headless Chromes, then their clones
#   free-disk.sh xcode                 older iOS DeviceSupport builds, unavailable simulators
#   free-disk.sh deriveddata [--dry-run]  Xcode DerivedData of worktrees that are gone
#   free-disk.sh worktrees [--dry-run] [--committed-hours N] [--uncommitted-hours N]
#                                      worktrees nobody has changed for a while
#   free-disk.sh coredevice [--dry-run]   the app install deltas CoreDevice keeps
#
# status: the target is 20% of the disk (AGENTS_FREE_TARGET_PCT moves it; #4699), twice
# the 10% line machine.disk_low fires at, so a run ends well past the line and not on it.
# It exits 0 when free space is at the target or over it, and 1 when it is under.
#
# worktrees: the worktrees under <main checkout>/.agents/worktrees that nobody has changed
# for a while (Alex, 2026-11-11, #4699). It needs no session list, so a person can run it.
# The last change is the newest file's mtime, leaving out .git and build output (build,
# .build, DerivedData, node_modules). A worktree goes, with `git worktree remove --force`,
# when one of these is true:
#   - all its work is committed, and nothing changed for N hours (--committed-hours, 4);
#   - it has uncommitted work, and nothing changed for N hours (--uncommitted-hours, 8).
#     That work is lost: --force removes it.
# It keeps a worktree any process has as its working folder, a detached HEAD with commits
# that are on no branch, a locked one, and anything that is not a linked worktree of the
# main checkout. The branch stays, with every commit. --dry-run says what it would remove.
#
# coredevice: CoreDevice keeps a delta of each app it installs on a device
# (AppInstallationBinaryDeltas, 15 GB here on 2026-11-11), so the next install sends only
# what changed. It removes them when no devicectl runs; the next install sends the whole app.
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
		if grep -qxF "$(basename "$d")" <<<"$open"; then
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
		if [ -n "$builds" ] && grep -qF -e "$name" -e "$(dirname "$ws")" <<<"$builds"; then
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

# The newest mtime, in seconds, of a file in $1, leaving out .git and build output.
last_change() {
	find "$1" \( -name .git -o -name build -o -name .build -o -name DerivedData -o -name node_modules \) -prune \
		-o -type f -exec stat -f '%m' {} + 2>/dev/null | awk '$1 > m { m = $1 } END { if (m) print m }'
}

worktrees() {
	local dry=0 committed=4 uncommitted=8
	while [ $# -gt 0 ]; do
		case $1 in
		--dry-run) dry=1 ;;
		--committed-hours) committed=$2; shift ;;
		--uncommitted-hours) uncommitted=$2; shift ;;
		*) die "worktrees [--dry-run] [--committed-hours N] [--uncommitted-hours N]" ;;
		esac
		shift
	done
	local main
	main=$(dirname "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)")
	main=$(cd "$main" && pwd -P)
	[ -d "$main/.agents/worktrees" ] || { echo "no worktrees"; return 0; }
	local listed cwds now w name last hours dirty limit k freed=0 removed=0 verb=removing
	[ "$dry" = 0 ] || verb="would remove"
	listed=$(git -C "$main" worktree list --porcelain)
	# Every process's working folder: a session or a build in a worktree keeps it.
	cwds=$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)
	now=$(date +%s)
	for w in "$main"/.agents/worktrees/*/; do
		w=$(cd "$w" && pwd -P) || continue
		name=$(basename "$w")
		if [ "$w" = "$main" ] || ! grep -qxF "worktree $w" <<<"$listed"; then
			echo "kept $name: not a linked worktree of $main"
			continue
		fi
		if [ "$(git -C "$w" rev-parse --path-format=absolute --git-dir)" = \
			"$(git -C "$w" rev-parse --path-format=absolute --git-common-dir)" ]; then
			echo "kept $name: a main checkout"
			continue
		fi
		if awk -v w="worktree $w" '$0 == w { f = 1; next } /^worktree / { f = 0 } f && /^locked/ { found = 1 } END { exit !found }' <<<"$listed"; then
			echo "kept $name: locked"
			continue
		fi
		if awk -v w="$w" '$0 == w || index($0, w "/") == 1 { found = 1 } END { exit !found }' <<<"$cwds"; then
			echo "kept $name: a process works in it"
			continue
		fi
		if ! git -C "$w" symbolic-ref -q HEAD >/dev/null &&
			[ -n "$(git -C "$w" rev-list -n 1 HEAD --not --branches --remotes)" ]; then
			echo "kept $name: detached, with commits on no branch"
			continue
		fi
		last=$(last_change "$w")
		hours=$(((now - ${last:-$now}) / 3600))
		dirty=$(git -C "$w" status --porcelain --untracked-files=all | wc -l | tr -d ' ')
		if [ "$dirty" -gt 0 ]; then limit=$uncommitted; else limit=$committed; fi
		if [ "$hours" -lt "$limit" ]; then
			echo "kept $name: changed ${hours}h ago, under ${limit}h ($dirty uncommitted)"
			continue
		fi
		k=$(du -sk "$w" | cut -f1)
		echo "$verb $name ($(gb "$k") GB): unchanged for ${hours}h, $dirty uncommitted, branch $(git -C "$w" symbolic-ref -q --short HEAD || echo detached) kept"
		if [ "$dry" = 0 ] && ! git -C "$main" worktree remove --force "$w"; then
			echo "kept $name: git worktree remove failed"
			continue
		fi
		freed=$((freed + k))
		removed=$((removed + 1))
	done
	[ "$dry" = 1 ] || git -C "$main" worktree prune
	if [ "$dry" = 1 ]; then
		echo "would remove $removed worktree(s), $(gb "$freed") GB"
	else
		echo "removed $removed worktree(s), $(gb "$freed") GB"
	fi
}

coredevice() {
	local dry=0
	while [ $# -gt 0 ]; do
		case $1 in
		--dry-run) dry=1 ;;
		*) die "coredevice [--dry-run]" ;;
		esac
		shift
	done
	local d="$HOME/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas" k
	[ -d "$d" ] || { echo "no CoreDevice install deltas"; return 0; }
	if pgrep -q devicectl; then
		echo "kept CoreDevice install deltas: a devicectl runs"
		return 0
	fi
	k=$(du -sk "$d" | cut -f1)
	if [ "$dry" = 1 ]; then
		echo "would remove CoreDevice install deltas ($(gb "$k") GB)"
	else
		find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
		echo "removed CoreDevice install deltas ($(gb "$k") GB)"
	fi
}

case ${1:-} in
status) status ;;
chromes) shift; chromes "$@" ;;
xcode) xcode ;;
deriveddata) shift; deriveddata "$@" ;;
worktrees) shift; worktrees "$@" ;;
coredevice) shift; coredevice "$@" ;;
*) sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
