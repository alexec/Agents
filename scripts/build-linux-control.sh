#!/bin/zsh
# agents-control for Linux (058, T068): the Go control plane (#1137), static, for x86_64 and
# aarch64, and beside each workspace-commands (#691, #806, Go since #1364), the command
# provider the control plane looks for next to itself. Built through Go/scripts/go.sh (a
# container on this Mac; lease "build"), with no swift.org toolchain (#1314). They land in
# deploy/bin/, named by Docker's TARGETARCH.
set -euo pipefail

root=${0:A:h:h}
out=$root/deploy/bin
mkdir -p $out $root/Go/out/servers
version=$(git -C $root describe --tags --always 2>/dev/null || echo dev)
typeset -A docker=(x86_64 amd64 aarch64 arm64)
arches=("$@")
(( $#arches )) || arches=(aarch64 x86_64)
for arch in $arches; do
    for product in agents-control workspace-commands; do
        print "building $product for $arch-linux…"
        GOOS=linux GOARCH=${docker[$arch]} CGO_ENABLED=0 $root/Go/scripts/go.sh build -trimpath \
            -ldflags "-s -w -X github.com/alexec/agents/Go/internal/buildinfo.Version=$version" \
            -o out/servers/$product-linux-${docker[$arch]} ./cmd/$product
        cp $root/Go/out/servers/$product-linux-${docker[$arch]} $out/$product-linux-${docker[$arch]}
        print "  $out/$product-linux-${docker[$arch]} ($(( $(stat -f %z $out/$product-linux-${docker[$arch]}) / 1048576 )) MB)"
    done
done

# The web remote (071), built here as it is not checked in (#473), so the image can serve it
# when asked to: the listener stays off unless the container is given --web /web and --web-port.
$root/scripts/web.sh build
rm -rf $root/deploy/web
cp -R $root/Web/dist $root/deploy/web
print "  $root/deploy/web (the web remote, off unless asked for)"
