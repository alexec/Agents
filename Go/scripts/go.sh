#!/bin/sh
# Runs the Go toolchain for the module at Go/ (#1135). On a Mac it runs in a golang
# container, so Go is not installed on the Mac (#1134); on Linux with Go on the PATH (CI,
# the devbox) it runs that Go. Module and build caches live in
# ~/Library/Caches/Agents-build/go (AGENTS_BUILD_CACHE moves the parent), shared by every
# worktree, as scripts/build-cache.sh shares the Swift ones. Lease "build" first.
#
#   Go/scripts/go.sh test ./...
#   Go/scripts/go.sh vet ./...
#   GOOS=linux GOARCH=amd64 Go/scripts/go.sh build -o out/agentsd ./cmd/agentsd
#
# Paths are inside Go/, from any folder; the whole repository is there as `..` (wiregen
# reads Packages/Wire and writes Web/). GOOS, GOARCH and GOFLAGS pass through; the
# container's own is linux on this Mac's architecture. GO_IMAGE picks another image.
set -e
mod=$(cd "$(dirname "$0")/.." && pwd)
repo=$(dirname "$mod")
# On a Mac with no Docker running and Go installed (a CI runner), that Go.
if command -v go >/dev/null 2>&1 && { [ "$(uname -s)" != Darwin ] || ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; }; then
	cd "$mod"
	exec go "$@"
fi
cache="${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}/go"
mkdir -p "$cache/gopath" "$cache/gocache"
exec docker run --rm -v "$repo":/repo -v "$cache/gopath":/go -v "$cache/gocache":/root/.cache/go-build \
	-e CGO_ENABLED=0 -e GOOS -e GOARCH -e GOFLAGS -w /repo/Go "${GO_IMAGE:-golang:1.26}" go "$@"
