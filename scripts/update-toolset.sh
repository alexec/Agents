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
#
# Or a runtime the vendor ships as a signed archive per platform (049), from the ACP registry:
#
#   ./scripts/update-toolset.sh --archive <runtime> <registry-id> [--min-free-bytes N]
#   ./scripts/update-toolset.sh --archive antigravity antigravity-acp --min-free-bytes 1000000000
#
# Writes App/Resources/toolsets/<runtime>/manifest.json only: each platform's URL (dl.google.com
# and nothing else), size, SHA-256 (the registry has none, so every archive is downloaded and
# hashed here), command and arguments. `knownBroken` reasons already in the manifest are kept.
# The id is the SHA-256 of that file. The archives themselves are never kept or committed.
#
# Or a runtime whose vendor publishes one program per platform as GitHub release assets
# (049, OpenCode):
#
#   ./scripts/update-toolset.sh --archive-github <runtime> <owner/repo> <tag> [--min-free-bytes N]
#   ./scripts/update-toolset.sh --archive-github opencode anomalyco/opencode v1.18.33 --min-free-bytes 500000000
#
# Every `<runtime>-<os>-<arch>[-baseline][-musl].{zip,tar.gz}` asset becomes a platform
# (arm64 → aarch64, x64 → x86_64, darwin/linux only), with GitHub's own `digest` and `size`:
# nothing is downloaded. Only github.com release URLs of that repo are accepted, and the
# vendor's desktop app (`<runtime>-desktop-*`) is skipped. The program inside is `<runtime>`.
set -euo pipefail

root=${0:A:h:h}

if [[ ${1:-} == --archive-github ]]; then
  runtime=${2:?runtime id, e.g. opencode}
  repo=${3:?owner/repo, e.g. anomalyco/opencode}
  tag=${4:?release tag, e.g. v1.18.33}
  shift 4
  min_free=500000000
  while (( $# )); do
    case $1 in
      --min-free-bytes) min_free=$2; shift 2 ;;
      *) print -u2 "unknown option $1"; exit 2 ;;
    esac
  done
  out=$root/App/Resources/toolsets/$runtime
  mkdir -p $out
  gh api "repos/$repo/releases/tags/$tag" | RUNTIME=$runtime REPO=$repo TAG=$tag MIN_FREE=$min_free OUT=$out python3 -c '
import json, os, re, sys
release = json.load(sys.stdin)
runtime, repo, tag, out = os.environ["RUNTIME"], os.environ["REPO"], os.environ["TAG"], os.environ["OUT"]
prefix = f"https://github.com/{repo}/releases/download/"
pattern = re.compile(rf"^{re.escape(runtime)}-(darwin|linux)-(arm64|x64)((?:-baseline)?(?:-musl)?)\.(zip|tar\.gz)$")
arch = {"arm64": "aarch64", "x64": "x86_64"}
platforms = {}
for asset in release["assets"]:
    match = pattern.match(asset["name"])
    if not match:
        continue
    url = asset["browser_download_url"]
    if not url.startswith(prefix):
        sys.exit(f"refusing {url}: not a {repo} release download")
    digest = asset.get("digest") or ""
    if not digest.startswith("sha256:"):
        sys.exit(asset["name"] + " has no sha256 digest on GitHub")
    os_name, cpu, variant, _ = match.groups()
    platforms[f"{os_name}-{arch[cpu]}{variant}"] = {
        "url": url, "sha256": digest.removeprefix("sha256:"), "size": asset["size"],
        "command": runtime, "arguments": []}
for needed in ("darwin-aarch64", "darwin-x86_64", "linux-x86_64", "linux-aarch64"):
    if needed not in platforms:
        sys.exit(f"{tag} has no {needed} asset")
manifest = {"runtimeID": runtime, "kind": "archive", "version": tag.removeprefix("v"),
            "source": f"github:{repo}@{tag}", "minFreeBytes": int(os.environ["MIN_FREE"]),
            "platforms": platforms}
with open(f"{out}/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"Wrote {out}/manifest.json ({tag}, {len(platforms)} platforms)")
'
  exit 0
fi

if [[ ${1:-} == --archive ]]; then
  runtime=${2:?runtime id, e.g. antigravity}
  registry_id=${3:?ACP registry id, e.g. antigravity-acp}
  shift 3
  min_free=1000000000
  while (( $# )); do
    case $1 in
      --min-free-bytes) min_free=$2; shift 2 ;;
      *) print -u2 "unknown option $1"; exit 2 ;;
    esac
  done
  out=$root/App/Resources/toolsets/$runtime
  work=$(mktemp -d /tmp/$runtime-archive.XXXX)
  trap 'rm -rf $work' EXIT
  curl -fsSL "https://raw.githubusercontent.com/agentclientprotocol/registry/main/$registry_id/agent.json" \
    -o $work/agent.json
  mkdir -p $out
  RUNTIME=$runtime REGISTRY_ID=$registry_id MIN_FREE=$min_free WORK=$work OUT=$out python3 - <<'PY'
import hashlib, json, os, subprocess, sys
work, out = os.environ["WORK"], os.environ["OUT"]
agent = json.load(open(f"{work}/agent.json"))
old = {}
try:
    old = json.load(open(f"{out}/manifest.json")).get("platforms", {})
except FileNotFoundError:
    pass
platforms = {}
for name, entry in sorted(agent["distribution"]["binary"].items()):
    if not (name.startswith("darwin-") or name.startswith("linux-")):
        continue
    url = entry["archive"]
    if not url.startswith("https://dl.google.com/"):
        sys.exit(f"refusing {url}: not on dl.google.com")
    path = f"{work}/{name}.zip"
    print(f"downloading {name}…", file=sys.stderr)
    subprocess.run(["curl", "-fsSL", "-o", path, url], check=True)
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    platform = {
        "url": url,
        "sha256": digest.hexdigest(),
        "size": os.path.getsize(path),
        "command": entry["cmd"].removeprefix("./"),
        "arguments": entry.get("args", []),
    }
    if old.get(name, {}).get("knownBroken"):
        platform["knownBroken"] = old[name]["knownBroken"]
    platforms[name] = platform
    os.remove(path)
manifest = {
    "runtimeID": os.environ["RUNTIME"],
    "kind": "archive",
    "version": agent["version"],
    "source": f"acp-registry:{os.environ['REGISTRY_ID']}",
    "minFreeBytes": int(os.environ["MIN_FREE"]),
    "platforms": platforms,
}
with open(f"{out}/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  print "Wrote $out/manifest.json ($(python3 -c "import json;print(json.load(open('$out/manifest.json'))['version'])"))"
  exit 0
fi

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
