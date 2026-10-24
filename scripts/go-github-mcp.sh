#!/bin/sh
# The github MCP server (#1232), or another Go MCP server named last (linear-mcp, #839, gitlab-mcp, #1629, email-mcp, #1780, or
# workspace-commands, #1364, the command machine provider agents-control looks for beside
# itself), for Agents Host to carry beside agentsd (#700): what Agents Host's build runs first. Builds
# Go/out/helpers/<name>, for both Mac architectures, when a Go source is newer than it. With no
# way to run Go here (no Docker and no Go), it leaves none and warns: the app still builds,
# without it.
#
#   scripts/go-github-mcp.sh                       build github-mcp if stale
#   scripts/go-github-mcp.sh --force               build it whatever
#   scripts/go-github-mcp.sh --carry               Agents Host's build, after its phases: copy it
#                                                  into the app's Contents/Helpers and sign it, or
#                                                  take it out
#   scripts/go-github-mcp.sh [--force|--carry] linear-mcp    the same for Go/cmd/linear-mcp
#   scripts/go-github-mcp.sh [--force|--carry] gitlab-mcp
#   scripts/go-github-mcp.sh [--force|--carry] email-mcp
#   scripts/go-github-mcp.sh [--force|--carry] workspace-commands
#
# agentsd puts Contents/Helpers first on an MCP server's PATH, so `.agents/mcp.json` names it
# by its bare name, "command": "github-mcp".
set -eu

mode=
case "${1:-}" in --force | --carry) mode=$1; shift ;; esac
name=${1:-github-mcp}
case "$name" in github-mcp | linear-mcp | gitlab-mcp | email-mcp | workspace-commands) ;; *) echo "go-github-mcp.sh: no Go MCP server $name" >&2; exit 2 ;; esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/Go/out/helpers/$name"
# An Xcode script phase has a bare PATH: look where Docker and Go are usually installed too.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"

if [ "$mode" = --carry ]; then
	helpers="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers"
	if [ ! -x "$out" ]; then
		rm -f "$helpers/$name"
		exit 0
	fi
	mkdir -p "$helpers"
	ditto "$out" "$helpers/$name"
	flags="--force --options runtime"
	[ "${CONFIGURATION:-Debug}" = Debug ] || flags="$flags --timestamp"
	# shellcheck disable=SC2086
	codesign $flags --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helpers/$name"
	exit 0
fi

if [ "$mode" != --force ] && [ -x "$out" ] &&
	[ -z "$(find "$root/Go" -name '*.go' -newer "$out" 2>/dev/null | head -1)" ] &&
	[ ! "$root/Go/go.mod" -nt "$out" ] && [ ! "$root/Go/go.sum" -nt "$out" ]; then
	exit 0
fi

if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; } && ! command -v go >/dev/null 2>&1; then
	echo "warning: go-github-mcp.sh: no Docker running and no Go here, so Agents Host carries no $name." >&2
	rm -f "$out"
	exit 0
fi

version=$(git -C "$root" describe --tags --always 2>/dev/null || echo dev)
mkdir -p "$root/Go/out/helpers"
tmp=$(mktemp -d "$root/Go/out/helpers/.build-$name.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for arch in arm64 amd64; do
	if ! GOOS=darwin GOARCH=$arch "$root/Go/scripts/go.sh" build -trimpath \
		-ldflags "-s -w -X github.com/alexec/agents/Go/internal/buildinfo.Version=$version" \
		-o "out/helpers/$(basename "$tmp")/$name-$arch" "./cmd/$name"; then
		echo "warning: go-github-mcp.sh: $name did not build for $arch, so Agents Host carries none." >&2
		rm -f "$out"
		exit 0
	fi
done
lipo -create -output "$tmp/$name" "$tmp/$name-arm64" "$tmp/$name-amd64"
chmod 755 "$tmp/$name"
mv -f "$tmp/$name" "$out"
