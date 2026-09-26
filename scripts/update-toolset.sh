#!/bin/zsh
# Pin one runtime's toolset: Node.js and the npm package that speaks ACP for it. The app
# installs it on this Mac (048) and on servers (043).
#
#   ./scripts/update-toolset.sh <runtime> <node-version> <package> <version> \
#       --platform-package <pattern> [--min-free-bytes N] [--forwards-arguments]
#
#   ./scripts/update-toolset.sh claude v24.21.0 @agentclientprotocol/claude-agent-acp 0.81.2 \
#       --platform-package claude-agent-sdk-
#   ./scripts/update-toolset.sh codex v24.21.0 @agentclientprotocol/codex-acp 1.13.1 \
#       --platform-package codex- --min-free-bytes 1073741824
#
# Writes App/Resources/toolsets/<runtime>/:
#   manifest.json       Node's version and the SHA-256 of its two Linux tarballs, from
#                       nodejs.org's SHASUMS256.txt; the package, its entry, and the room needed
#   package.json        one dependency, pinned exactly
#   package-lock.json   npm's own lock: every package with its sha512 `integrity`, including
#                       the runtime's per-platform packages for every platform, so `npm ci` on
#                       a Linux server or either kind of Mac takes its own and checks it
#   mac-node.json       the same Node's two macOS tarballs and their SHA-256, for the Mac's
#                       own copy (048). Beside the manifest, not in it: see below
# A toolset's id is the SHA-256 of manifest.json + package-lock.json, so any change here is a
# new toolset, installed on each server at its next connect. mac-node.json is not part of the
# id, so pinning the Mac's Node never makes a server reinstall.
#
# `--platform-package` is the name every per-platform package starts with; the lock must hold
# one for linux-x64, linux-arm64, darwin-x64 and darwin-arm64, or nothing is written.
set -euo pipefail

root=${0:A:h:h}
runtime=${1:?runtime id, e.g. codex}
node_version=${2:?node version, e.g. v24.21.0}
package=${3:?npm package, e.g. @agentclientprotocol/codex-acp}
version=${4:?package version, e.g. 1.13.1}
shift 4
platform_package=""
min_free=838860800
forwards=0
while (( $# )); do
  case $1 in
    --platform-package) platform_package=$2; shift 2 ;;
    --min-free-bytes) min_free=$2; shift 2 ;;
    --forwards-arguments) forwards=1; shift ;;
    *) print -u2 "unknown option $1"; exit 2 ;;
  esac
done
[[ -n $platform_package ]] || { print -u2 "--platform-package is required"; exit 2; }
[[ $node_version == v* ]] || node_version="v$node_version"
out=$root/App/Resources/toolsets/$runtime

sums=$(curl -fsSL "https://nodejs.org/dist/$node_version/SHASUMS256.txt")
sha() { print -r -- "$sums" | awk -v f="node-$node_version-linux-$1.tar.xz" '$2 == f { print $1 }'; }
x64=$(sha x64); arm64=$(sha arm64)
[[ -n $x64 && -n $arm64 ]] || { print -u2 "No Linux tarballs for $node_version in SHASUMS256.txt"; exit 1; }
# The Mac's, as .tar.gz: nodejs.org ships darwin as gz and xz, and gz needs nothing extra.
mac_sha() { print -r -- "$sums" | awk -v f="node-$node_version-$1.tar.gz" '$2 == f { print $1 }'; }
typeset -A mac
for p in darwin-arm64 darwin-x64; do
  mac[$p]=$(mac_sha $p)
  [[ -n ${mac[$p]} ]] || { print -u2 "No $p tarball for $node_version in SHASUMS256.txt"; exit 1; }
done

bin=$(npm view "$package@$version" bin --json | python3 -c 'import json,sys; b=json.load(sys.stdin); print(next(iter(b.values())) if isinstance(b, dict) else b)')
[[ -n $bin ]] || { print -u2 "$package@$version has no bin entry"; exit 1; }

work=$(mktemp -d /tmp/$runtime-toolset.XXXX)
trap 'rm -rf $work' EXIT
cat > $work/package.json <<JSON
{
  "name": "agents-$runtime-toolset",
  "private": true,
  "dependencies": { "$package": "$version" }
}
JSON
(cd $work && npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null)

for p in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
  grep -q "$platform_package$p\"" $work/package-lock.json || { print -u2 "the lock has no $platform_package$p package"; exit 1; }
done

mkdir -p $out
cp $work/package.json $work/package-lock.json $out/
# forwardsArguments only when asked, so a toolset that has never needed it keeps the same
# manifest bytes, and so the same id, as before the option existed.
forwards_line=""
(( forwards )) && forwards_line=$'\n  "forwardsArguments": true,'
cat > $out/manifest.json <<JSON
{
  "runtimeID": "$runtime",
  "node": {
    "version": "$node_version",
    "sha256": { "x86_64": "$x64", "aarch64": "$arm64" }
  },
  "package": "$package",
  "packageVersion": "$version",
  "entry": "${bin#./}",$forwards_line
  "minFreeBytes": $min_free
}
JSON

cat > $out/mac-node.json <<JSON
{
  "version": "$node_version",
  "sha256": { "arm64": "${mac[darwin-arm64]}", "x64": "${mac[darwin-x64]}" }
}
JSON

print "wrote $out ($node_version, $package@$version, toolset $(cat $out/manifest.json $out/package-lock.json | shasum -a 256 | cut -c1-16))"
