#!/bin/bash
# One build cache shared by every worktree and scratch build on this Mac (#234), so a
# fresh worktree does not fetch and compile again what another already has.
#
#   build-cache.sh xcodebuild ARGS...      xcodebuild with the shared caches
#   build-cache.sh swift build|test ARGS...  swift with the shared package cache
#   build-cache.sh dir                     where the cache is
#   build-cache.sh du                      its size, by part
#   build-cache.sh prune [--max-gb N] [--go-max-gb M]
#                                          bring the Swift part under N GB (default 30) and
#                                          Go's under M GB (default 10); safe any time
#
# The cache lives outside every worktree, so deleting a worktree's own build/ and .build
# (the clean-up rule) leaves it alone. AGENTS_BUILD_CACHE moves it; AGENTS_BUILD_CACHE=off
# runs the command as it is, with nothing shared.
#
# `swift test` gets AGENTS_QUARANTINE=1 unless it is set already: tests marked
# .flakyUnderLoad skip, and `eventually` waits as long as on CI, as a local full run is
# as loaded as a runner. AGENTS_QUARANTINE=0 (or AGENTS_RUN_FLAKY=1) runs them.
#
#   cas/            Xcode's compilation cache (COMPILATION_CACHE_CAS_PATH): compiler
#                   outputs keyed by their inputs, with source and build paths mapped
#                   out, so a second worktree replays them. Bounded by Xcode itself.
#   packages/       remote package repositories, fetched once (-packageCachePath)
#   checkouts/<k>/  the packages checked out (-clonedSourcePackagesDirPath), one folder
#                   per set of Package.resolved files, so lanes on the same pins share
#                   one and a lane on other pins never changes it under them
#   swiftpm/        `swift build` and `swift test`'s cache (--cache-path)
#   linux/<k>/      what the Swift Linux agentsd builds left (#856) before #1314; prune
#                   takes it away
#   go/             Go/scripts/go.sh's and scripts/lint.sh's: gopath/ (modules), gocache/
#                   (Go's build cache) and lint/ (golangci-lint's). Bounded by prune on its
#                   own, so a large Go cache never costs the Swift one (#1796).
#   npm/            scripts/lint.sh's Biome download
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
	(cd "$top" && cat Packages/*/Package.resolved 2>/dev/null) |
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
		# Quoted as one item of the list: Xcode splits these settings on spaces (#1417).
		SWIFT_OTHER_PREFIX_MAPPINGS="\"$PWD=/^worktree\""
		CLANG_OTHER_PREFIX_MAPPINGS="\"$PWD=/^worktree\""
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
	for d in cas packages checkouts swiftpm linux go npm; do
		[ -d "$CACHE/$d" ] && echo "  $d $(gb "$CACHE/$d") GB"
	done
	echo "  total $(gb "$CACHE") GB"
}

# Nothing here is needed by a build that is not running: everything can be fetched or
# compiled again. So prune drops the oldest checkouts folders first, then the package
# repositories and SwiftPM's cache, and the compilation cache last, and never while a
# build might be using what it drops. Go's part has a bound of its own: its build cache
# goes by age (Go marks an entry used when it reads it), and never while Go runs.
building() { pgrep -qf 'xcodebuild|swift-build|swift-test|swiftpm-testing-helper|swift-frontend'; }
going() { pgrep -qf 'Go/scripts/go.sh|golang:|golangci'; }

# The Swift part: everything prune can drop for the bound, Go's and npm's aside.
SWIFT_PARTS="cas packages checkouts swiftpm linux"
kb_of() { local t=0 d k; for d in "$@"; do [ -e "$d" ] || continue; k=$(du -sk "$d" | cut -f1); t=$((t + k)); done; echo "$t"; }
swift_kb() { local d a=(); for d in $SWIFT_PARTS; do a+=("$CACHE/$d"); done; kb_of "${a[@]}"; }
go_kb() { kb_of "$CACHE/go"; }

# Folders under DIR not changed in a week; nothing when DIR is not there.
unused_week() { [ -d "$1" ] || return 0; find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -mtime +7 -print; }

# Go folders no script writes any more: the first go.sh's (#1135) beside go/, and a GOPATH
# laid out straight in go/ before gopath/ was its own folder.
OLD_GO="go-build go-mod gocache gopath go/build go/cache go/mod go/github.com go/golang.org go/go.yaml.in"

prune() {
	local max=30 gomax=10
	while [ $# -gt 0 ]; do
		case $1 in
		--max-gb) max=$2; shift ;;
		--go-max-gb) gomax=$2; shift ;;
		*) die "prune [--max-gb N] [--go-max-gb M]" ;;
		esac
		shift
	done
	[ -d "$CACHE" ] || { echo "no cache at $CACHE"; return; }
	local kb=$((max * 1048576)) gokb=$((gomax * 1048576)) d days
	echo "before: $(gb "$CACHE") GB; bounds: Swift $max GB, Go $gomax GB"
	# Checkouts nobody built with in a week go regardless; they are small, but they add up.
	unused_week "$CACHE/checkouts" | while IFS= read -r d; do echo "removing $d (unused a week)"; rm -rf "$d"; done
	unused_week "$CACHE/linux" | while IFS= read -r d; do echo "removing $d (unused a week)"; rm -rf "$d"; done
	if [ "$(swift_kb)" -gt "$kb" ]; then
		if building; then
			echo "Swift part over the bound, but a build is running: left as it is"
		else
			# Oldest first; the newest checkouts folder is the one main builds with.
			# shellcheck disable=SC2010 # checkouts/<k> names are hash keys (checkouts_key), never with spaces
			for d in $(ls -1t "$CACHE/checkouts" 2>/dev/null | grep -v '\.lock$' | tail -n +2 | tail -r) packages swiftpm linux cas; do
				[ "$(swift_kb)" -gt "$kb" ] || break
				case $d in packages | swiftpm | linux | cas) d=$CACHE/$d ;; *) d=$CACHE/checkouts/$d ;; esac
				[ -e "$d" ] || continue
				echo "removing $d ($(gb "$d") GB)"
				rm -rf "$d"
			done
		fi
	fi
	if going; then
		echo "Go is running: its part left as it is ($(gb "$CACHE/go") GB)"
	else
		for d in $OLD_GO; do
			[ -e "$CACHE/$d" ] || continue
			echo "removing $CACHE/$d ($(gb "$CACHE/$d") GB, no longer used)"
			# Go makes its module files read-only.
			chmod -R u+w "$CACHE/$d" 2>/dev/null || true
			rm -rf "${CACHE:?}/$d"
		done
		# Build cache entries not used in a week, then three days, one, and then all of it.
		for days in 7 3 1 0; do
			[ "$(go_kb)" -gt "$gokb" ] && [ -d "$CACHE/go/gocache" ] || break
			if [ "$days" = 0 ]; then
				echo "removing $CACHE/go/gocache ($(gb "$CACHE/go/gocache") GB)"
				rm -rf "$CACHE/go/gocache"
			else
				echo "removing Go build cache entries unused for $days days"
				find "$CACHE/go/gocache" -type f -mtime +"$days" -delete 2>/dev/null || true
			fi
		done
		if [ "$(go_kb)" -gt "$gokb" ] && [ -d "$CACHE/go/lint" ]; then
			echo "removing $CACHE/go/lint ($(gb "$CACHE/go/lint") GB)"
			rm -rf "$CACHE/go/lint"
		fi
	fi
	echo "after: $(gb "$CACHE") GB"
}

[ "${1:-} ${2:-}" != "swift test" ] || export AGENTS_QUARANTINE=${AGENTS_QUARANTINE:-1}

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
*) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
