#!/bin/zsh
# Pin the Gemini toolset the app installs on this Mac (048's set-up page) and on servers (043):
# Node.js and Gemini CLI, which speaks ACP itself with `--acp` (046).
#
#   ./scripts/update-gemini-toolset.sh <node-version> <gemini-cli-version>
#   ./scripts/update-gemini-toolset.sh v24.21.0 0.61.0
#
# Writes App/Resources/toolsets/gemini/ in the same shape as Claude's (see
# update-claude-toolset.sh): manifest.json, package.json, package-lock.json and mac-node.json.
# Two differences. `forwardsArguments` is true, because Gemini's shim is handed `--acp` and the
# policy file's `--policy <path>`, where Claude's adapter takes none. And the room needed is
# smaller: Gemini is one bundled package of about 100 MB beside Node.
#
# The version is also written into RuntimeCatalog.gemini's comment by hand; a unit test checks
# the two agree, so a pin moved here and not there is a red test rather than a surprise.
set -euo pipefail

root=${0:A:h:h}
node_version=${1:?node version, e.g. v24.21.0}
gemini_version=${2:?gemini-cli version, e.g. 0.61.0}
[[ $node_version == v* ]] || node_version="v$node_version"
package=@google/gemini-cli
out=$root/App/Resources/toolsets/gemini

sums=$(curl -fsSL "https://nodejs.org/dist/$node_version/SHASUMS256.txt")
sha() { print -r -- "$sums" | awk -v f="node-$node_version-linux-$1.tar.xz" '$2 == f { print $1 }'; }
x64=$(sha x64); arm64=$(sha arm64)
[[ -n $x64 && -n $arm64 ]] || { print -u2 "No Linux tarballs for $node_version in SHASUMS256.txt"; exit 1; }
mac_sha() { print -r -- "$sums" | awk -v f="node-$node_version-$1.tar.gz" '$2 == f { print $1 }'; }
typeset -A mac
for p in darwin-arm64 darwin-x64; do
  mac[$p]=$(mac_sha $p)
  [[ -n ${mac[$p]} ]] || { print -u2 "No $p tarball for $node_version in SHASUMS256.txt"; exit 1; }
done

engines=$(npm view "$package@$gemini_version" engines.node)
print "gemini-cli $gemini_version wants node $engines"
bin=$(npm view "$package@$gemini_version" bin --json | python3 -c 'import json,sys; b=json.load(sys.stdin); print(b.get("gemini") if isinstance(b, dict) else b)')
[[ -n $bin && $bin != None ]] || { print -u2 "$package@$gemini_version has no gemini bin"; exit 1; }

work=$(mktemp -d /tmp/gemini-toolset.XXXX)
trap 'rm -rf $work' EXIT
cat > $work/package.json <<JSON
{
  "name": "agents-gemini-toolset",
  "private": true,
  "dependencies": { "$package": "$gemini_version" }
}
JSON
(cd $work && npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null)

mkdir -p $out
cp $work/package.json $work/package-lock.json $out/
cat > $out/manifest.json <<JSON
{
  "runtimeID": "gemini",
  "node": {
    "version": "$node_version",
    "sha256": { "x86_64": "$x64", "aarch64": "$arm64" }
  },
  "package": "$package",
  "packageVersion": "$gemini_version",
  "entry": "${bin#./}",
  "forwardsArguments": true,
  "minFreeBytes": 419430400
}
JSON

cat > $out/mac-node.json <<JSON
{
  "version": "$node_version",
  "sha256": { "arm64": "${mac[darwin-arm64]}", "x64": "${mac[darwin-x64]}" }
}
JSON

print "wrote $out ($node_version, $package@$gemini_version, toolset $(cat $out/manifest.json $out/package-lock.json | shasum -a 256 | cut -c1-16))"
