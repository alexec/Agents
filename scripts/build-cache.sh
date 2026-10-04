#!/bin/bash
# One build cache shared by every worktree and scratch build on this Mac (#234), so a
# fresh worktree does not fetch and compile again what another already has.
#
#   build-cache.sh xcodebuild ARGS...      xcodebuild with the shared caches
#   build-cache.sh swift build|test ARGS...  swift with the shared package cache
#   build-cache.sh dir                     where the cache is
#   build-cache.sh du                      its size, by part
#   build-cache.sh prune [--max-gb N]      bring it under N GB (default 30); safe any time
#
# The cache lives outside every worktree, so deleting a worktree's own build/ and .build
# (the clean-up rule) leaves it alone. AGENTS_BUILD_CACHE moves it; AGENTS_BUILD_CACHE=off
# runs the command as it is, with nothing shared.
#
#   cas/            Xcode's compilation cache (COMPILATION_CACHE_CAS_PATH): compiler
#                   outputs keyed by their inputs, with source and build paths mapped
#                   out, so a second worktree replays them. Bounded by Xcode itself.
#   packages/       remote package repositories, fetched once (-packageCachePath)
#   checkouts/<k>/  the packages checked out (-clonedSourcePackagesDirPath), one folder
#                   per set of Package.resolved files, so lanes on the same pins share
#                   one and a lane on other pins never changes it under them
#   swiftpm/        `swift build` and `swift test`'s cache (--cache-path)
#
# What is not shared: DerivedData and .build. Their contents name the worktree's own
# paths, and SwiftPM locks .build for one process at a time, so a shared one would make
# lanes rebuild each other's or wait.
set -euo pipefail

CACHE=${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}
# Xcode trims the compilation cache to this after a build; prune keeps the rest in step.
CAS_LIMIT_GB=20

die() { echo "build-cache.sh: $*" >&2; exit 1; }

# The worktree this is run in, for the Package.resolved files that pick a checkouts/ folder.
repo() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

checkouts_key() {
	local top
	top=$(repo)
	# Every pinned package set the apps build with; the spikes under specs/ are not built.
	(cd "$top" && cat Daemon/Package.resolved Packages/*/Package.resolved 2>/dev/null) |
		shasum | cut -c1-12
}

# A lock on a folder: mkdir is atomic. Stale after 15 minutes (a killed resolve).
lock() {
	local l=$1 i
	for i in $(seq 1 900); do
		mkdir "$l" 2>/dev/null && return 0
		[ -n "$(find "$l" -maxdepth 0 -mmin +15 2>/dev/null)" ] && { rmdir "$l" 2>/dev/null || true; continue; }
		[ "$i" = 1 ] && echo "build-cache.sh: another build is resolving packages into $(dirname "$l"); waiting" >&2
		sleep 1
	done
	die "gave up waiting for $l"
}

xcode() {
	local key co
	[ -d Agents.xcodeproj ] || die "run from the repository's top, after xcodegen generate"
	key=$(checkouts_key)
	co=$CACHE/checkouts/$key
	mkdir -p "$CACHE/cas" "$CACHE/packages" "$co"
	touch "$co" # prune keeps the folders used lately
	local flags=(
		-packageCachePath "$CACHE/packages"
		-clonedSourcePackagesDirPath "$co"
		COMPILATION_CACHE_ENABLE_CACHING=YES
		COMPILATION_CACHE_CAS_PATH="$CACHE/cas"
		COMPILATION_CACHE_LIMIT_SIZE="${CAS_LIMIT_GB}G"
		# Keys without the worktree's own paths in them (its source and its DerivedData),
		# so another worktree hits. Without the project mappings only the SDK and the
		# toolchain are mapped, and a second worktree misses on every package (#234).
		SWIFT_ENABLE_PREFIX_MAPPING=YES
		CLANG_ENABLE_PREFIX_MAPPING=YES
		SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES
		CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES
		# The project mappings leave the explicit modules' folders in DerivedData unmapped.
		# The path as the build sees it, which under /tmp is not git's /private/tmp.
		SWIFT_OTHER_PREFIX_MAPPINGS="$PWD=/^worktree"
		CLANG_OTHER_PREFIX_MAPPINGS="$PWD=/^worktree"
	)
	# Two builds resolving into one checkouts folder at once can each write it: the first
	# build on a new key resolves it under a lock and keeps the project's Package.resolved
	# beside it; every build after copies that in and builds without resolving.
	local pins=Agents.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
	if [ ! -e "$co/Package.resolved" ]; then
		lock "$co.lock"
		trap 'rmdir "$co.lock" 2>/dev/null || true' EXIT
		if [ ! -e "$co/Package.resolved" ]; then
			xcodebuild -resolvePackageDependencies "${flags[@]:0:4}" >&2
			cp "$pins" "$co/Package.resolved"
		fi
		rmdir "$co.lock" 2>/dev/null || true
		trap - EXIT
	fi
	mkdir -p "$(dirname "$pins")"
	cp "$co/Package.resolved" "$pins"
	exec xcodebuild "$@" "${flags[@]}" -disableAutomaticPackageResolution
}

swiftpm() {
	local sub=${1:-}
	case $sub in build | test | run | package) ;; *) die "swift $sub: only build, test, run or package" ;; esac
	shift
	mkdir -p "$CACHE/swiftpm"
	exec swift "$sub" --cache-path "$CACHE/swiftpm" "$@"
}

gb() { du -sk "$1" 2>/dev/null | awk '{printf "%.1f", $1 / 1048576}'; }

usage_report() {
	local d
	echo "$CACHE"
	for d in cas packages checkouts swiftpm; do
		[ -d "$CACHE/$d" ] && echo "  $d $(gb "$CACHE/$d") GB"
	done
	echo "  total $(gb "$CACHE") GB"
}

# Nothing here is needed by a build that is not running: everything can be fetched or
# compiled again. So prune drops the oldest checkouts folders first, then the package
# repositories and SwiftPM's cache, and the compilation cache last, and never while a
# build might be using what it drops.
building() { pgrep -qf 'xcodebuild|swift-build|swift-test|swiftpm-testing-helper|swift-frontend'; }

prune() {
	local max=30
	while [ $# -gt 0 ]; do
		case $1 in
		--max-gb) max=$2; shift ;;
		*) die "prune [--max-gb N]" ;;
		esac
		shift
	done
	[ -d "$CACHE" ] || { echo "no cache at $CACHE"; return; }
	local kb=$((max * 1048576)) d
	size() { du -sk "$CACHE" | cut -f1; }
	echo "before: $(gb "$CACHE") GB, bound $max GB"
	# Checkouts nobody built with in a week go regardless; they are small, but they add up.
	find "$CACHE/checkouts" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -mtime +7 -print 2>/dev/null |
		while IFS= read -r d; do echo "removing $d (unused a week)"; rm -rf "$d"; done
	if [ "$(size)" -gt "$kb" ]; then
		if building; then
			echo "over the bound, but a build is running: left as it is"
		else
			# Oldest first; the newest checkouts folder is the one main builds with.
			for d in $(ls -1t "$CACHE/checkouts" 2>/dev/null | grep -v '\.lock$' | tail -n +2 | tail -r) packages swiftpm cas; do
				[ "$(size)" -gt "$kb" ] || break
				case $d in packages | swiftpm | cas) d=$CACHE/$d ;; *) d=$CACHE/checkouts/$d ;; esac
				[ -e "$d" ] || continue
				echo "removing $d ($(gb "$d") GB)"
				rm -rf "$d"
			done
		fi
	fi
	echo "after: $(gb "$CACHE") GB"
}

[ "$CACHE" != off ] || case ${1:-} in
	xcodebuild) shift; exec xcodebuild "$@" ;;
	swift) shift; exec swift "$@" ;;
	esac

case ${1:-} in
xcodebuild) shift; xcode "$@" ;;
swift) shift; swiftpm "$@" ;;
dir) echo "$CACHE" ;;
du) usage_report ;;
prune) shift; prune "$@" ;;
*) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
