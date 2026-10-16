#!/bin/sh
# Runs the Go toolchain in a container (no Go on this Mac). Module and build caches
# live in ~/Library/Caches/Agents-build/go-spike, shared by every run.
# Usage: ./go.sh build ./...   |   GOOS=darwin ./go.sh build -o out/agentsd-darwin ./cmd/agentsd
set -e
here=$(cd "$(dirname "$0")" && pwd)
cache="$HOME/Library/Caches/Agents-build/go-spike"
mkdir -p "$cache/gopath" "$cache/gocache"
exec docker run --rm -v "$here":/src -v "$cache/gopath":/go -v "$cache/gocache":/root/.cache/go-build \
  -e CGO_ENABLED=0 -e GOOS="${GOOS:-linux}" -e GOARCH="${GOARCH:-arm64}" -e GOFLAGS="${GOFLAGS:-}" \
  -w /src golang:1.25 go "$@"
