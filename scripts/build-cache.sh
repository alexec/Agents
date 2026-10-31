#!/bin/bash
# One build cache shared by every worktree and scratch build on this Mac (#234), so a
# fresh worktree does not fetch and compile again what another already has.
#
#   build-cache.sh xcodebuild ARGS...      xcodebuild with the shared caches
#   build-cache.sh swift build|test ARGS...  swift with the shared package cache
#   build-cache.sh dir                     where the cache is
#   build-cache.sh du                      its size, by part
#   build-cache.sh prune [--max-gb N] [--go-max-gb M]
#                                          bring the cache under N GB (default 15), Go's
#                                          part under M GB of it (default 3); safe any time
#
# The cache lives outside every worktree, so deleting a worktree's own build/ and .build
# (the clean-up rule) leaves it alone. AGENTS_BUILD_CACHE moves it; AGENTS_BUILD_CACHE=off
# runs the command as it is, with nothing shared.
#
# The cache has a bound (#2346): each xcodebuild and swift run prunes it behind the build,
# at most once in 30 minutes, to AGENTS_BUILD_CACHE_MAX_GB (default 15) with Go's part
# under AGENTS_BUILD_CACHE_GO_MAX_GB (default 3), into prune.log in the cache.
# AGENTS_BUILD_CACHE_PRUNE=off stops that. A prune never removes a folder that a running
# build named in in-use/<pid>.
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
#   in-use/<pid>    the folders the build with that pid uses; prune keeps them
#   pruned, prune.log  when the last prune behind a build ran, and what it did
#
# What is not shared: DerivedData and .build. Their contents name the worktree's own
# paths, and SwiftPM locks .build for one process at a time, so a shared one would make
# lanes rebuild each other's or wait.
#
# An xcodebuild that names no -derivedDataPath gets <worktree>/build/DerivedData (#2684),
# not Xcode's ~/Library/Developer/Xcode/DerivedData/Agents-<hash>: deleting the worktree's
# build/ then deletes its build output too. AGENTS_BUILD_CACHE=off keeps Xcode's default.
set -euo pipefail

CACHE=${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}
MAX_GB=${AGENTS_BUILD_CACHE_MAX_GB:-15}
GO_MAX_GB=${AGENTS_BUILD_CACHE_GO_MAX_GB:-3}
# Xcode trims the compilation cache to this after a build: the Swift part's bound less
# 2 GB for the packages and checkouts, at least 1 GB.
CAS_LIMIT_GB=$(awk -v m="$MAX_GB" -v g="$GO_MAX_GB" 'BEGIN { c = int(m - g - 2); print (c < 1 ? 1 : c) }')
# The processes that are builds, for a build that wrote no in-use/<pid> (an older script).
BUILD_PROCS=${AGENTS_BUILD_CACHE_PROCS:-xcodebuild|swift-build|swift-test}

die() { echo "build-cache.sh: $*" >&2; exit 1; }

# The worktree this is run in, for the Package.resolved files that pick a checkouts/ folder.
repo() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

checkouts_key() {
	local top
	top=$(repo)
	# Every pinned package set the apps build with; the spikes under specs/ are not built.
	# And the packages project.yml names itself (FluidAudio, #2322), which no
	# Package.resolved holds: a package added there is a new set.
	(cd "$top" && cat Packages/*/Package.resolved 2>/dev/null && sed -n '/^packages:/,/^targets:/p' project.yml) |
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
	using "$co" "$CACHE/packages" "$CACHE/cas"
	auto_prune
	# The worktree's own DerivedData, unless the command names one (#2684). It is under
	# $PWD, so the prefix mappings below keep it out of the cache keys. An action that
	# builds nothing gets no -derivedDataPath.
	local dd=(-derivedDataPath "$PWD/build/DerivedData") a prev= target=() rdd=()
	for a in "$@"; do
		case $a in
		-derivedDataPath | -exportArchive | -exportLocalizations | -importLocalizations | -version | -showsdks | -list | -help | -usage | -license) dd=() ;;
		esac
		# What the cold-cache resolve below needs from the command (#2773).
		case $prev in
		-project | -workspace | -scheme) target+=("$prev" "$a") ;;
		-derivedDataPath) rdd=(-derivedDataPath "$a") ;;
		esac
		prev=$a
	done
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
		# Each DerivedData here is under $PWD (build/DerivedData, or a caller's build/DD).
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
			# xcodebuild refuses -derivedDataPath without -scheme (#2773): the resolve takes
			# the command's project and scheme, and a DerivedData only with a scheme.
			[ ${#rdd[@]} -gt 0 ] || rdd=(-derivedDataPath "$PWD/build/DerivedData")
			case " ${target[*]-} " in *" -scheme "*) ;; *) rdd=() ;; esac
			xcodebuild -resolvePackageDependencies ${target[@]+"${target[@]}"} "${flags[@]:0:4}" ${rdd[@]+"${rdd[@]}"} >&2
			cp "$pins" "$co/Package.resolved"
		fi
		rmdir "$co.lock" 2>/dev/null || true
		trap - EXIT
	fi
	mkdir -p "$(dirname "$pins")"
	cp "$co/Package.resolved" "$pins"
	exec xcodebuild "$@" ${dd[@]+"${dd[@]}"} "${flags[@]}" -disableAutomaticPackageResolution
}

swiftpm() {
	local sub=${1:-}
	case $sub in build | test | run | package) ;; *) die "swift $sub: only build, test, run or package" ;; esac
	shift
	mkdir -p "$CACHE/swiftpm"
	using "$CACHE/swiftpm"
	auto_prune
	exec swift "$sub" --cache-path "$CACHE/swiftpm" "$@"
}

gb() { du -sk "$1" 2>/dev/null | awk '{printf "%.1f", $1 / 1048576}'; }
kb_gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }
gb_kb() { awk -v g="$1" 'BEGIN { printf "%d", g * 1048576 }'; }

# This build uses these folders: prune keeps them while this pid runs (exec keeps the
# pid), and their times say when each was used last, for prune's order.
using() {
	mkdir -p "$CACHE/in-use"
	printf '%s\n' "$@" >"$CACHE/in-use/$$"
	touch "$@"
}

# The folders running builds use, one a line; "all" when a build runs that said nothing,
# as one from a worktree on an older script does. A marker whose pid ended goes.
in_use() {
	local f pid ppid
	for f in "$CACHE"/in-use/*; do
		[ -e "$f" ] || continue
		pid=${f##*/}
		if kill -0 "$pid" 2>/dev/null; then cat "$f"; else rm -f "$f"; fi
	done
	for pid in $(pgrep -f "$BUILD_PROCS" || true); do
		[ -e "$CACHE/in-use/$pid" ] && continue
		ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		[ -n "$ppid" ] && [ -e "$CACHE/in-use/$ppid" ] && continue
		echo all
		return
	done
}

# Prune behind the build, so it never waits: at most once in 30 minutes, one at a time.
auto_prune() {
	[ "${AGENTS_BUILD_CACHE_PRUNE:-on}" != off ] || return 0
	[ -z "$(find "$CACHE/prune.lock" -maxdepth 0 -mmin +60 2>/dev/null)" ] || rmdir "$CACHE/prune.lock" 2>/dev/null || true
	[ -z "$(find "$CACHE/pruned" -mmin -30 2>/dev/null)" ] || return 0
	mkdir "$CACHE/prune.lock" 2>/dev/null || return 0
	touch "$CACHE/pruned"
	(
		prune || true
		rmdir "$CACHE/prune.lock" 2>/dev/null || true
	) </dev/null >"$CACHE/prune.log" 2>&1 &
}

usage_report() {
	local d
	echo "$CACHE"
	for d in cas packages checkouts swiftpm linux go npm; do
		[ -d "$CACHE/$d" ] && echo "  $d $(gb "$CACHE/$d") GB"
	done
	echo "  total $(gb "$CACHE") GB"
}

# Nothing here is needed by a build that is not running: everything can be fetched or
# compiled again. So prune drops the Swift part's folders by last use, oldest first, and
# never one a running build uses. Go's part has a bound of its own: its build cache goes
# by age (Go marks an entry used when it reads it), and never while Go runs.
going() { pgrep -qf 'Go/scripts/go.sh|golang:|golangci'; }

kb_of() { local t=0 d k; for d in "$@"; do [ -e "$d" ] || continue; k=$(du -sk "$d" | cut -f1); t=$((t + k)); done; echo "$t"; }
go_kb() { kb_of "$CACHE/go"; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

# The Swift part's folders, the oldest used first: each checkouts/<k>, the package
# repositories, SwiftPM's cache, what the Linux builds left, and the compilation cache.
units() {
	local d
	for d in "$CACHE"/checkouts/* "$CACHE/packages" "$CACHE/swiftpm" "$CACHE/linux" "$CACHE/cas"; do
		[ -d "$d" ] || continue
		case $d in *.lock) continue ;; esac
		echo "$(mtime "$d") $d"
	done | sort -n | cut -d' ' -f2-
}
swift_kb() { local d a=(); while IFS= read -r d; do a+=("$d"); done < <(units); kb_of ${a[@]+"${a[@]}"}; }

# Folders under DIR not changed in a week; nothing when DIR is not there.
unused_week() { [ -d "$1" ] || return 0; find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -mtime +7 -print; }

# Go folders no script writes any more: the first go.sh's (#1135) beside go/, and a GOPATH
# laid out straight in go/ before gopath/ was its own folder.
OLD_GO="go-build go-mod gocache gopath go/build go/cache go/mod go/github.com go/golang.org go/go.yaml.in"

prune() {
	local max=$MAX_GB gomax=$GO_MAX_GB
	while [ $# -gt 0 ]; do
		case $1 in
		--max-gb) max=$2; shift ;;
		--go-max-gb) gomax=$2; shift ;;
		*) die "prune [--max-gb N] [--go-max-gb M]" ;;
		esac
		shift
	done
	[ -d "$CACHE" ] || { echo "no cache at $CACHE"; return; }
	local gokb kb before total size d days inuse
	gokb=$(gb_kb "$gomax")
	kb=$(($(gb_kb "$max") - gokb))
	[ "$kb" -gt 0 ] || die "prune: --max-gb $max leaves nothing over Go's $gomax GB"
	before=$(kb_of "$CACHE")
	echo "before: $(kb_gb "$before") GB; bound $max GB, of it Go $gomax GB"
	inuse=$(in_use)
	# Checkouts nobody built with in a week go regardless; they are small, but they add up.
	unused_week "$CACHE/checkouts" | while IFS= read -r d; do
		printf '%s\n' "$inuse" | grep -qxF -e "$d" -e all && continue
		echo "removing $d (unused a week)"; rm -rf "$d"
	done
	unused_week "$CACHE/linux" | while IFS= read -r d; do echo "removing $d (unused a week)"; rm -rf "$d"; done
	total=$(swift_kb)
	while IFS= read -r d; do
		[ "$total" -gt "$kb" ] || break
		if printf '%s\n' "$inuse" | grep -qxF -e "$d" -e all; then
			echo "kept $d: a running build uses it"
			continue
		fi
		size=$(kb_of "$d")
		echo "removing $d ($(kb_gb "$size") GB)"
		rm -rf "$d"
		total=$((total - size))
	done < <(units)
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
	total=$(kb_of "$CACHE")
	echo "after: $(kb_gb "$total") GB; freed $(kb_gb $((before - total))) GB"
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
*) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
