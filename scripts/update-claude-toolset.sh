#!/bin/zsh
# Pin the Claude toolset the app installs on servers (043): Node.js and the ACP adapter.
#
#   ./scripts/update-claude-toolset.sh <node-version> <claude-agent-acp-version>
#   ./scripts/update-claude-toolset.sh v24.21.0 0.81.2
#
# Writes App/Resources/toolsets/claude/:
#   manifest.json       Node's version and the SHA-256 of its two Linux tarballs, from
#                       nodejs.org's SHASUMS256.txt; the package, its entry, and the room needed
#   package.json        one dependency, pinned exactly
#   package-lock.json   npm's own lock: every package with its sha512 `integrity`, including
#                       the SDK's per-platform packages for every platform, so `npm ci` on a
#                       Linux server takes its own and checks it
#   mac-node.json       the same Node's two macOS tarballs and their SHA-256, for the Mac's
#                       own copy of Claude (048). Beside the manifest, not in it: see below
# A server's toolset id is the SHA-256 of manifest.json + package-lock.json, so any change
# here is a new toolset and is installed on each server at its next connect. mac-node.json
# is not part of the id, so pinning the Mac's Node never makes a server reinstall.
set -euo pipefail

root=${0:A:h:h}
node_version=${1:?node version, e.g. v24.21.0}
acp_version=${2:?claude-agent-acp version, e.g. 0.81.2}
[[ $node_version == v* ]] || node_version="v$node_version"
package=@agentclientprotocol/claude-agent-acp
out=$root/App/Resources/toolsets/claude

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

bin=$(npm view "$package@$acp_version" bin --json | python3 -c 'import json,sys; b=json.load(sys.stdin); print(next(iter(b.values())) if isinstance(b, dict) else b)')
[[ -n $bin ]] || { print -u2 "$package@$acp_version has no bin entry"; exit 1; }

work=$(mktemp -d /tmp/claude-toolset.XXXX)
trap 'rm -rf $work' EXIT
cat > $work/package.json <<JSON
{
  "name": "agents-claude-toolset",
  "private": true,
  "dependencies": { "$package": "$acp_version" }
}
JSON
(cd $work && npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null)

mkdir -p $out
cp $work/package.json $work/package-lock.json $out/
cat > $out/manifest.json <<JSON
{
  "runtimeID": "claude",
  "node": {
    "version": "$node_version",
    "sha256": { "x86_64": "$x64", "aarch64": "$arm64" }
  },
  "package": "$package",
  "packageVersion": "$acp_version",
  "entry": "${bin#./}",
  "minFreeBytes": 838860800
}
JSON

cat > $out/mac-node.json <<JSON
{
  "version": "$node_version",
  "sha256": { "arm64": "${mac[darwin-arm64]}", "x64": "${mac[darwin-x64]}" }
}
JSON

for p in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
  grep -q "claude-agent-sdk-$p\"" $out/package-lock.json || { print -u2 "the lock has no $p SDK package"; exit 1; }
done
print "wrote $out ($node_version, $package@$acp_version, toolset $(cat $out/manifest.json $out/package-lock.json | shasum -a 256 | cut -c1-16))"
