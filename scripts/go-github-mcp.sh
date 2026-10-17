#!/bin/sh
# The github MCP server (#1232), for Agents Host to carry beside agentsd as it carries
# ci-watcher (#700): what Agents Host's build runs first. Builds Go/out/helpers/github-mcp,
# for both Mac architectures, when a Go source is newer than it. With no way to run Go here
# (no Docker and no Go), it leaves none and warns: the app still builds, without it.
#
#   scripts/go-github-mcp.sh            build it if stale
#   scripts/go-github-mcp.sh --force    build it whatever
#   scripts/go-github-mcp.sh --carry    Agents Host's build, after its phases: copy it into the
#                                       app's Contents/Helpers and sign it, or take it out
#
# agentsd puts Contents/Helpers first on an MCP server's PATH, so `.agents/mcp.json` names it
# by its bare name, "command": "github-mcp".
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/Go/out/helpers/github-mcp"
# An Xcode script phase has a bare PATH: look where Docker and Go are usually installed too.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"

if [ "${1:-}" = --carry ]; then
	helpers="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers"
	if [ ! -x "$out" ]; then
		rm -f "$helpers/github-mcp"
		exit 0
	fi
	mkdir -p "$helpers"
	ditto "$out" "$helpers/github-mcp"
	flags="--force --options runtime"
	[ "${CONFIGURATION:-Debug}" = Debug ] || flags="$flags --timestamp"
	# shellcheck disable=SC2086
	codesign $flags --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helpers/github-mcp"
	exit 0
fi

if [ "${1:-}" != --force ] && [ -x "$out" ] &&
	[ -z "$(find "$root/Go" -name '*.go' -newer "$out" 2>/dev/null | head -1)" ] &&
	[ ! "$root/Go/go.mod" -nt "$out" ] && [ ! "$root/Go/go.sum" -nt "$out" ]; then
	exit 0
fi

if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; } && ! command -v go >/dev/null 2>&1; then
	echo "warning: go-github-mcp.sh: no Docker running and no Go here, so Agents Host carries no github MCP server." >&2
	rm -f "$out"
	exit 0
fi

version=$(git -C "$root" describe --tags --always 2>/dev/null || echo dev)
mkdir -p "$root/Go/out/helpers"
tmp=$(mktemp -d "$root/Go/out/helpers/.build.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for arch in arm64 amd64; do
	if ! GOOS=darwin GOARCH=$arch "$root/Go/scripts/go.sh" build -trimpath \
		-ldflags "-s -w -X github.com/alexec/agents/Go/internal/buildinfo.Version=$version" \
		-o "out/helpers/$(basename "$tmp")/github-mcp-$arch" ./cmd/github-mcp; then
		echo "warning: go-github-mcp.sh: the github MCP server did not build for $arch, so Agents Host carries none." >&2
		rm -f "$out"
		exit 0
	fi
done
lipo -create -output "$tmp/github-mcp" "$tmp/github-mcp-arm64" "$tmp/github-mcp-amd64"
chmod 755 "$tmp/github-mcp"
mv -f "$tmp/github-mcp" "$out"
