#!/bin/zsh
# Build agentsd for Linux servers (037): two static binaries the app copies over ssh.
#
#   ./scripts/build-linux-agentsd.sh           # build both, copy into App/Resources/servers
#   ./scripts/build-linux-agentsd.sh --check   # build both, copy nothing (the pre-merge gate)
#
# Needs the swift.org toolchain matching Xcode's Swift version and its Static Linux SDK
# (see specs/037-cloud-agents/quickstart.md). Xcode's own toolchain cannot use the SDK.
#
# What it writes, per architecture (x86_64, aarch64):
#   agentsd-linux-<arch>          the binary, stripped
#   agentsd-linux-<arch>.sha256   its SHA-256, which is its identity: the installer names
#                                 it on the server by this and compares it on every connect
# and once:
#   VERSION                       MARKETING_VERSION+CURRENT_PROJECT_VERSION from project.yml,
#                                 used only to refuse a server running a newer app's build
set -euo pipefail

root=${0:A:h:h}
check=0
[[ ${1:-} == --check ]] && check=1

swift_version=$(xcrun swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)
[[ $swift_version == *.*.* ]] || swift_version="$swift_version.0"
toolchain=~/Library/Developer/Toolchains/swift-$swift_version-RELEASE.xctoolchain
swift=$toolchain/usr/bin/swift
if [[ ! -x $swift ]]; then
    print -u2 "No swift.org $swift_version toolchain at $toolchain. See specs/037-cloud-agents/quickstart.md."
    exit 1
fi

marketing=$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?/\1/p' $root/project.yml | head -1)
build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([^"]+)"?/\1/p' $root/project.yml | head -1)
out=$root/App/Resources/servers

for arch in x86_64 aarch64; do
    print "building agentsd for $arch-linux…"
    $swift build --package-path $root/Daemon -c release \
        --swift-sdk $arch-swift-linux-musl --product agentsd \
        -Xswiftc -gnone -Xlinker -s
    bin=$($swift build --package-path $root/Daemon -c release --swift-sdk $arch-swift-linux-musl --show-bin-path)/agentsd
    file $bin | grep -q "statically linked" || { print -u2 "$bin is not static"; exit 1; }
    size=$(stat -f %z $bin)
    print "  $bin ($((size / 1048576)) MB)"
    if (( ! check )); then
        mkdir -p $out
        cp $bin $out/agentsd-linux-$arch
        shasum -a 256 $out/agentsd-linux-$arch | cut -d' ' -f1 > $out/agentsd-linux-$arch.sha256
    fi
done

if (( ! check )); then
    print -n "$marketing+$build" > $out/VERSION
    print "wrote $out (version $marketing+$build)"
fi
