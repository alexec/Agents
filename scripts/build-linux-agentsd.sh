#!/bin/zsh
# Build agentsd for Linux servers (037): two static binaries the app copies over ssh, and
# beside each the MCP servers Agents ships (#700), which a host puts next to agentsd.
#
#   ./scripts/build-linux-agentsd.sh           # build both, copy into App/Resources/servers
#   ./scripts/build-linux-agentsd.sh --check   # build both, copy nothing (the pre-merge gate)
#   ./scripts/build-linux-agentsd.sh --check x86_64   # one architecture (CI's linux job, #805)
#
# Needs the swift.org toolchain matching Xcode's Swift version and its Static Linux SDK
# (see specs/037-cloud-agents/quickstart.md). Xcode's own toolchain cannot use the SDK.
#
# What it writes, per architecture (x86_64, aarch64):
#   agentsd-linux-<arch>          the binary, stripped
#   agentsd-linux-<arch>.sha256   its SHA-256, which is its identity: the installer names
#                                 it on the server by this and compares it on every connect
#   ci-watcher-linux-<arch>       the CI watcher (Packages/MCPServers), and its .sha256
# and once:
#   VERSION                       MARKETING_VERSION+CURRENT_PROJECT_VERSION from project.yml,
#                                 used only to refuse a server running a newer app's build
#
# The two architectures build side by side, each in a scratch folder of its own (#856). What
# one built is kept in the shared build cache (scripts/build-cache.sh), under the git trees
# it was built from, so a ship from a fresh worktree copies it rather than spending minutes
# on the same build. Only with nothing uncommitted under those trees; --check always builds.
set -euo pipefail

root=${0:A:h:h}
check=0
[[ ${1:-} == --check ]] && { check=1; shift }
arches=("$@")
(( $#arches )) || arches=(x86_64 aarch64)

# SWIFT names the swift.org toolchain's swift outright: the release workflow builds on Linux
# (#669), where there is no xcrun and the toolchain is the one on PATH.
if [[ -n ${SWIFT:-} ]]; then
    swift=$SWIFT
else
    swift_version=$(xcrun swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)
    [[ $swift_version == *.*.* ]] || swift_version="$swift_version.0"
    toolchain=~/Library/Developer/Toolchains/swift-$swift_version-RELEASE.xctoolchain
    swift=$toolchain/usr/bin/swift
    if [[ ! -x $swift ]]; then
        print -u2 "No swift.org $swift_version toolchain at $toolchain. See specs/037-cloud-agents/quickstart.md."
        exit 1
    fi
fi

# A release names its own version (#669); otherwise project.yml's.
marketing=${AGENTS_MARKETING_VERSION:-$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?/\1/p' $root/project.yml | head -1)}
build=${AGENTS_BUILD:-$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([^"]+)"?/\1/p' $root/project.yml | head -1)}
out=$root/App/Resources/servers

sha256() { if (( $+commands[shasum] )); then shasum -a 256 $1; else sha256sum $1; fi | cut -d' ' -f1 }

# The cache key: everything the binaries are built from, or nothing when that is not all
# committed. AGENTS_BUILD_CACHE=off turns the cache off, as for build-cache.sh.
cache=${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}
inputs=(Daemon Packages/AgentsKit Packages/MCPServers)
key=
if (( ! check )) && [[ $cache != off ]] && git -C $root rev-parse -q --verify HEAD >/dev/null 2>&1 \
    && [[ -z $(git -C $root status --porcelain -- $inputs) ]]; then
    key=$( { $swift --version 2>&1; print $marketing+$build; git -C $root rev-parse ${inputs/#/HEAD:} } \
        | { if (( $+commands[shasum] )); then shasum; else sha256sum; fi } | cut -c1-16)
fi

# One architecture: agentsd and the MCP servers, into $1, in a .build folder of its own so the
# two can build at once (SwiftPM locks a .build for one process).
build_arch() {
    local arch=$1 dest=$2 pkg product bin
    for pkg product in Daemon agentsd Packages/MCPServers ci-watcher; do
        print "building $product for $arch-linux…"
        $swift build --package-path $root/$pkg --scratch-path $root/$pkg/.build/linux-$arch -c release \
            --swift-sdk $arch-swift-linux-musl --product $product \
            -Xswiftc -gnone -Xlinker -s
        bin=$($swift build --package-path $root/$pkg --scratch-path $root/$pkg/.build/linux-$arch -c release \
            --swift-sdk $arch-swift-linux-musl --show-bin-path)/$product
        file $bin | grep -q "statically linked" || { print -u2 "$bin is not static"; return 1 }
        print "  $bin ($(( $(wc -c < $bin) / 1048576 )) MB)"
        cp $bin $dest/$product-linux-$arch
    done
}

work=$(mktemp -d)
trap 'rm -rf $work' EXIT
built=()
for arch in $arches; do
    if [[ -n $key && -e $cache/linux/$key/$arch/done ]]; then
        print "agentsd for $arch-linux: unchanged since $cache/linux/$key, not rebuilt"
        continue
    fi
    mkdir -p $work/$arch
    { build_arch $arch $work/$arch; print $? > $work/$arch.status } > $work/$arch.log 2>&1 &
    built+=($arch)
done
wait
for arch in $built; do
    cat $work/$arch.log
    [[ $(<$work/$arch.status) == 0 ]] || { print -u2 "the $arch-linux build failed"; exit 1 }
    if [[ -n $key ]]; then
        # Into the cache whole or not at all: a folder renamed into place, marked done last.
        mkdir -p $cache/linux/$key
        rm -rf $cache/linux/$key/$arch
        mv $work/$arch $cache/linux/$key/$arch
        touch $cache/linux/$key/$arch/done
    fi
done

for arch in $arches; do
    from=$work/$arch
    [[ -n $key ]] && from=$cache/linux/$key/$arch && touch $cache/linux/$key
    (( check )) && continue
    mkdir -p $out
    for product in agentsd ci-watcher; do
        cp $from/$product-linux-$arch $out/$product-linux-$arch
        sha256 $out/$product-linux-$arch > $out/$product-linux-$arch.sha256
    done
done

if (( ! check )); then
    print -n "$marketing+$build" > $out/VERSION
    print "wrote $out (version $marketing+$build)"
    # The Go host beside it (#1136), for install.sh --impl go. Seconds where Go runs (a
    # container on this Mac, Go on PATH elsewhere); left out, with a word, where it cannot.
    if ! AGENTS_MARKETING_VERSION=$marketing AGENTS_BUILD=$build $root/scripts/build-linux-agentsd-go.sh; then
        print -u2 "warning: the Go host was not built (no Docker or Go here); servers get the Swift host only"
    fi
fi
