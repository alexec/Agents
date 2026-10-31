#!/bin/zsh
# Build the Linux host (#1136), Go: two static binaries install.sh installs (the Swift one went
# in #1314). And the github (#1232) and linear (#839) MCP servers, which every Linux host
# installs beside agentsd.
#
#   ./scripts/build-linux-agentsd.sh           # build both, copy into App/Resources/servers
#   ./scripts/build-linux-agentsd.sh --check   # build both, copy nothing
#
# What it writes, per architecture (x86_64, aarch64):
#   agentsd-linux-<arch>             the binary, static and stripped
#   agentsd-linux-<arch>.sha256      its SHA-256, its identity on the server
#   github-mcp-linux-<arch>          the github MCP server, and its .sha256
#   linear-mcp-linux-<arch>          the linear MCP server, and its .sha256
#   gitlab-mcp-linux-<arch>          the gitlab MCP server (#1629), and its .sha256
#   email-mcp-linux-<arch>           the email MCP server (#1780), and its .sha256
# and once:
#   VERSION                          the version, SemVer: scripts/version.sh, or on a release
#                                    AGENTS_MARKETING_VERSION, the tag's (#1748)
#
# Go runs through Go/scripts/go.sh (a container on this Mac): lease "build, test or scratch app" first. It takes
# seconds and needs no swift.org toolchain. The container mounts the repository, and Colima
# shares only your home folder: a checkout under /tmp fails with "go.mod file not found".
set -euo pipefail

root=${0:A:h:h}
# Stop at once, not with Go's "go.mod file not found" after the steps before it (#2221).
if [[ $(uname -s) == Darwin && $root/ != $HOME/* ]]; then
    print -u2 "build-linux-agentsd: $root is not under $HOME, and Go's container sees only the home folder: make the checkout under it (e.g. git worktree add --detach ~/.agents/scratch/<name> <ref>)"
    exit 1
fi
check=0
[[ ${1:-} == --check ]] && { check=1; shift }

version=${AGENTS_MARKETING_VERSION:-$($root/scripts/version.sh)}
out=$root/App/Resources/servers
work=$root/Go/out/servers
mkdir -p $work

sha256() { if (( $+commands[shasum] )); then shasum -a 256 $1; else sha256sum $1; fi | cut -d' ' -f1 }

for arch goarch in x86_64 amd64 aarch64 arm64; do
    for product cmd in agentsd agentsd github-mcp github-mcp linear-mcp linear-mcp gitlab-mcp gitlab-mcp email-mcp email-mcp; do
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
    for product in agentsd github-mcp linear-mcp gitlab-mcp email-mcp; do
        cp $work/$product-linux-$arch $out/$product-linux-$arch
        sha256 $out/$product-linux-$arch > $out/$product-linux-$arch.sha256
    done
done
print -n "$version" > $out/VERSION
rm -f $out/VERSION-go $out/agentsd-go-linux-*(N)  # the names before #1381
print "wrote the Go host, github-mcp, linear-mcp, gitlab-mcp and email-mcp into $out (version $version)"
