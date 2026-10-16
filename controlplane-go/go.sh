#!/bin/sh
# Runs the Go toolchain in a container (no Go on this Mac), as agentsd-go/go.sh does (#1125).
# Module and build caches live in ~/Library/Caches/Agents-build/go-spike, shared by every run.
#   ./go.sh test ./...    |    GOOS=darwin ./go.sh build -o out/darwin/agents-control ./cmd/agents-control
# GO_NETWORK names a docker network to join (the MinIO for the bucket tests: ./minio.sh).
set -e
here=$(cd "$(dirname "$0")" && pwd)
cache="$HOME/Library/Caches/Agents-build/go-spike"
mkdir -p "$cache/gopath" "$cache/gocache"
net=""
[ -n "$GO_NETWORK" ] && net="--network $GO_NETWORK"
exec docker run --rm $net -v "$here":/src -v "$cache/gopath":/go -v "$cache/gocache":/root/.cache/go-build \
  -e CGO_ENABLED=0 -e GOOS="${GOOS:-linux}" -e GOARCH="${GOARCH:-arm64}" -e GOFLAGS="${GOFLAGS:-}" \
  -e AGENTS_TEST_S3 -e AGENTS_STORE_ENDPOINT -e AGENTS_STORE_PATH_STYLE -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_REGION \
  -w /src golang:1.25 go "$@"
