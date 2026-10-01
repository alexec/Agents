#!/bin/zsh
# agents-control for Linux (058, T068): static musl binaries for x86_64 and aarch64, cross-built
# on this Mac with the swift.org toolchain and its static Linux SDK, as build-linux-agentsd.sh
# does for the daemon. They land in deploy/bin/, named by Docker's TARGETARCH.
set -euo pipefail

root=${0:A:h:h}
swift_version=$(xcrun swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)
[[ $swift_version == *.*.* ]] || swift_version="$swift_version.0"
swift=~/Library/Developer/Toolchains/swift-$swift_version-RELEASE.xctoolchain/usr/bin/swift
[[ -x $swift ]] || { print -u2 "No swift.org $swift_version toolchain. See specs/037-cloud-agents/quickstart.md."; exit 1 }

out=$root/deploy/bin
mkdir -p $out
typeset -A docker=(x86_64 amd64 aarch64 arm64)
arches=("$@")
(( $#arches )) || arches=(aarch64 x86_64)
for arch in $arches; do
    print "building agents-control for $arch-linux…"
    $swift build --package-path $root/Packages/ControlPlane -c release \
        --swift-sdk $arch-swift-linux-musl --product agents-control -Xswiftc -gnone -Xlinker -s
    bin=$($swift build --package-path $root/Packages/ControlPlane -c release --swift-sdk $arch-swift-linux-musl --show-bin-path)/agents-control
    file $bin | grep -q "statically linked" || { print -u2 "$bin is not static"; exit 1; }
    cp $bin $out/agents-control-linux-${docker[$arch]}
    print "  $out/agents-control-linux-${docker[$arch]} ($(( $(stat -f %z $bin) / 1048576 )) MB)"
done
