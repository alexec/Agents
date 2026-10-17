#!/bin/zsh
# Build the Linux host (#1136), Go: two static binaries install.sh installs (the Swift one went
# in #1314). And the github (#1232) and linear (#839) MCP servers, which every Linux host
# installs beside agentsd.
#
#   ./scripts/build-linux-agentsd-go.sh           # build both, copy into App/Resources/servers
#   ./scripts/build-linux-agentsd-go.sh --check   # build both, copy nothing
#
# What it writes, per architecture (x86_64, aarch64):
#   agentsd-go-linux-<arch>          the binary, static and stripped
#   agentsd-go-linux-<arch>.sha256   its SHA-256, its identity on the server
#   github-mcp-linux-<arch>          the github MCP server, and its .sha256
#   linear-mcp-linux-<arch>          the linear MCP server, and its .sha256
# and once:
#   VERSION-go                       MARKETING_VERSION+CURRENT_PROJECT_VERSION, as VERSION
#
# Go runs through Go/scripts/go.sh (a container on this Mac): lease "build" first. It takes
# seconds and needs no swift.org toolchain.
set -euo pipefail

root=${0:A:h:h}
check=0
[[ ${1:-} == --check ]] && { check=1; shift }

marketing=${AGENTS_MARKETING_VERSION:-$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?/\1/p' $root/project.yml | head -1)}
build=${AGENTS_BUILD:-$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([^"]+)"?/\1/p' $root/project.yml | head -1)}
version="$marketing+$build"
out=$root/App/Resources/servers
work=$root/Go/out/servers
mkdir -p $work

sha256() { if (( $+commands[shasum] )); then shasum -a 256 $1; else sha256sum $1; fi | cut -d' ' -f1 }

for arch goarch in x86_64 amd64 aarch64 arm64; do
    for product cmd in agentsd-go agentsd github-mcp github-mcp linear-mcp linear-mcp; do
        print "building $product for $arch-linux…"
        GOOS=linux GOARCH=$goarch $root/Go/scripts/go.sh build -trimpath \
            -ldflags "-s -w -X github.com/alexec/agents/Go/internal/buildinfo.Version=$version" \
            -o out/servers/$product-linux-$arch ./cmd/$cmd
        print "  $work/$product-linux-$arch ($(( $(wc -c < $work/$product-linux-$arch) / 1048576 )) MB)"
    done
done

(( check )) && exit 0
mkdir -p $out
for arch in x86_64 aarch64; do
    for product in agentsd-go github-mcp linear-mcp; do
        cp $work/$product-linux-$arch $out/$product-linux-$arch
        sha256 $out/$product-linux-$arch > $out/$product-linux-$arch.sha256
    done
done
print -n "$version" > $out/VERSION-go
print "wrote the Go host, github-mcp and linear-mcp into $out (version $version)"
