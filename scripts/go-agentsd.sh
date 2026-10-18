#!/bin/sh
# The Go agentsd (#1138), which Agents Host carries as Contents/Helpers/agentsd: what
# Agents Host's build runs first. Builds Go/out/helpers/agentsd, for both Mac architectures,
# when a Go source is newer than it. With no way to run Go here (no Docker and no Go) the
# build fails: since #1314 there is no Swift one to fall back on. As go-control.sh.
#
#   scripts/go-agentsd.sh            build it if stale
#   scripts/go-agentsd.sh --force    build it whatever
#   scripts/go-agentsd.sh --carry    Agents Host's build, after its phases: copy it into the
#                                    app's Contents/Helpers and sign it
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/Go/out/helpers/agentsd"
# An Xcode script phase has a bare PATH: look where Docker and Go are usually installed too.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"

if [ "${1:-}" = --carry ]; then
	helpers="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers"
	if [ ! -x "$out" ]; then
		echo "error: go-agentsd.sh: no $out to carry" >&2
		exit 1
	fi
	mkdir -p "$helpers"
	ditto "$out" "$helpers/agentsd"
	flags="--force --options runtime"
	[ "${CONFIGURATION:-Debug}" = Debug ] || flags="$flags --timestamp"
	# Signed with the identifier agentsd, so the callers' signature check
	# (CallerSignature: "agentsd" is an agent's own) and the window's take it as that, and
	# with the app group the window shares, where it listens for it (#1118).
	# shellcheck disable=SC2086
	codesign $flags --identifier agentsd --entitlements "$root/Host/agentsd.entitlements" \
		--sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helpers/agentsd"
	exit 0
fi

if [ "${1:-}" != --force ] && [ -x "$out" ] &&
	[ -z "$(find "$root/Go" -name '*.go' -newer "$out" 2>/dev/null | head -1)" ] &&
	[ ! "$root/Go/go.mod" -nt "$out" ] && [ ! "$root/Go/go.sum" -nt "$out" ]; then
	exit 0
fi

if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; } && ! command -v go >/dev/null 2>&1; then
	echo "error: go-agentsd.sh: no Docker running and no Go here, so Agents Host would carry no agentsd. Start Docker (colima start) or install Go." >&2
	exit 1
fi

version=$(git -C "$root" describe --tags --always 2>/dev/null || echo dev)
mkdir -p "$root/Go/out/helpers"
tmp=$(mktemp -d "$root/Go/out/helpers/.build.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for arch in arm64 amd64; do
	if ! GOOS=darwin GOARCH=$arch "$root/Go/scripts/go.sh" build -trimpath \
		-ldflags "-s -w -X github.com/alexec/agents/Go/internal/buildinfo.Version=$version" \
		-o "out/helpers/$(basename "$tmp")/agentsd-$arch" ./cmd/agentsd; then
		echo "error: go-agentsd.sh: agentsd did not build for $arch." >&2
		exit 1
	fi
done
lipo -create -output "$tmp/agentsd" "$tmp/agentsd-arm64" "$tmp/agentsd-amd64"
chmod 755 "$tmp/agentsd"
mv -f "$tmp/agentsd" "$out"
