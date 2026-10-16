#!/bin/zsh
# Build the Go Linux host (#1136) beside the Swift one: two static binaries a server can
# install with `install.sh --impl go`, or Add a Server's "Install the Go host" switch.
#
#   ./scripts/build-linux-agentsd-go.sh           # build both, copy into App/Resources/servers
#   ./scripts/build-linux-agentsd-go.sh --check   # build both, copy nothing
#
# What it writes, per architecture (x86_64, aarch64):
#   agentsd-go-linux-<arch>          the binary, static and stripped
#   agentsd-go-linux-<arch>.sha256   its SHA-256, its identity on the server
# and once:
#   VERSION-go                       MARKETING_VERSION+CURRENT_PROJECT_VERSION, as VERSION
#
# Go runs through Go/scripts/go.sh (a container on this Mac): lease "build" first. It takes
# seconds, not the Swift host's minutes, and needs no swift.org toolchain.
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
    print "building agentsd (go) for $arch-linux…"
    GOOS=linux GOARCH=$goarch $root/Go/scripts/go.sh build -trimpath \
        -ldflags "-s -w -X github.com/alexec/agents/Go/internal/buildinfo.Version=$version" \
        -o out/servers/agentsd-go-linux-$arch ./cmd/agentsd
    print "  $work/agentsd-go-linux-$arch ($(( $(wc -c < $work/agentsd-go-linux-$arch) / 1048576 )) MB)"
done

(( check )) && exit 0
mkdir -p $out
for arch in x86_64 aarch64; do
    cp $work/agentsd-go-linux-$arch $out/agentsd-go-linux-$arch
    sha256 $out/agentsd-go-linux-$arch > $out/agentsd-go-linux-$arch.sha256
done
print -n "$version" > $out/VERSION-go
print "wrote the Go host into $out (version $version)"
