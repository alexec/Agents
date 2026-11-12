#!/bin/sh
# Runs the Go toolchain for the module at Go/ (#1135). It is the Go on the PATH, on a Mac
# too (#4709): there is no container, so a run gets all of the Mac's cores. With no Go, it
# fails and says `brew install go`. On a Mac the module and build caches are in
# ~/Library/Caches/Agents-build/go (AGENTS_BUILD_CACHE moves the parent), shared by every
# worktree, as scripts/build-cache.sh shares the Swift ones; Go keys its build cache by
# GOOS, GOARCH and toolchain, so darwin and linux outputs do not mix. On CI and on Linux, Go's
# own caches. Lease "build" first.
#
#   Go/scripts/go.sh test ./...
#   Go/scripts/go.sh vet ./...
#   GOOS=linux GOARCH=amd64 Go/scripts/go.sh build -o out/agentsd ./cmd/agentsd
#
# Paths are inside Go/, from any folder (wiregen reads Packages/Wire and writes Web/ as
# `..`). On a Mac (not CI) Go runs with a clean environment, as the container gave it: only
# GOOS, GOARCH, GOFLAGS, GOBIN, CGO_ENABLED and DEVELOPER_DIR pass through, with HOME, USER, the
# caches and a PATH of Go and the system. A session's own PATH (a real codex before a test's
# fake one) and variables then do not reach the tests. TMPDIR is go/tmp in the cache: a
# folder with no symlink in its path and not under /private, as CI's go-darwin has
# ($RUNNER_TEMP); agentsd's tests fail under /var/folders, /tmp or /private/tmp. Cgo is off for `build` and `install`, as the binaries ship, except with
# -race, which needs it (#1505); for the rest it is Go's default, as in CI's go-darwin.
# CGO_ENABLED set by the caller wins.
set -e
mod=$(cd "$(dirname "$0")/.." && pwd)
# An Xcode script phase has a bare PATH: look where Go is usually installed too.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
if ! command -v go >/dev/null 2>&1; then
	echo "go.sh: no Go on the PATH: brew install go" >&2
	exit 127
fi
cd "$mod"
if [ "$(uname -s)" != Darwin ] || [ -n "${CI:-}" ]; then
	exec go "$@"
fi
cache="${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}/go"
mkdir -p "$cache/gopath" "$cache/gocache" "$cache/tmp"
cgo=${CGO_ENABLED:-}
if [ -z "$cgo" ]; then
	case ${1:-} in build | install) cgo=0 ;; esac
	for arg in "$@"; do
		[ "$arg" = -race ] && cgo=1
	done
fi
# GOROOT/bin, not /opt/homebrew/bin, where a real codex or claude may be too.
gobin=$(go env GOROOT)/bin
# The Go that go.mod names, as CI's setup-go takes it: Go fetches it once into the module
# cache, checked against its checksum database. The Mac's newer Go differs (#4709: one
# allocation bound of agentsd's fails under -race with go1.27).
toolchain=${GOTOOLCHAIN:-go$(awk '$1 == "go" { print $2; exit }' go.mod)}
set -- HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" TMPDIR="$cache/tmp" \
	PATH="$gobin:/usr/bin:/bin:/usr/sbin:/sbin" GOPATH="${GOPATH:-$cache/gopath}" \
	GOMODCACHE="${GOMODCACHE:-$cache/gopath/pkg/mod}" GOCACHE="${GOCACHE:-$cache/gocache}" GOTOOLCHAIN="$toolchain" \
	${GOLANGCI_LINT_CACHE:+GOLANGCI_LINT_CACHE="$GOLANGCI_LINT_CACHE"} ${cgo:+CGO_ENABLED="$cgo"} \
	${GOOS:+GOOS="$GOOS"} ${GOARCH:+GOARCH="$GOARCH"} ${GOFLAGS:+GOFLAGS="$GOFLAGS"} ${GOBIN:+GOBIN="$GOBIN"} \
	${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} go "$@"
# Not exec: scripts/build-cache.sh prune sees Go running by this script's name.
env -i "$@"
