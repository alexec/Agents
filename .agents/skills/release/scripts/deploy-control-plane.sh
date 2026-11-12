#!/usr/bin/env bash
# The release's control plane deploy (#2100, #3934): put a released version on the live control
# plane, control.agentloops.dev, with deploy/gcp/up.sh, and nothing else.
#
#   <scratch worktree>/.agents/skills/release/scripts/deploy-control-plane.sh [--dry-run] X.Y.Z
#
# .claude/settings.json allows this script and no other deploy, so Claude Code's auto-mode check
# does not refuse the release's deploy as a "Production Deploy" (#3934). That is safe because it
# deploys only what a release already published:
# - the version is X.Y.Z, and the tag vX.Y.Z is on origin;
# - this script's checkout is at that tag (the release's scratch worktree, step 8.2);
# - it gives up.sh no option but --dry-run: no --build, no keys, no other domain.
# Alex approved the deploy and its restart for every release (2026-10-22, #2100).
set -euo pipefail
die() { printf 'deploy-control-plane: %s\n' "$*" >&2; exit 1; }

dry_run=()
version=''
while (($#)); do
	case $1 in
	--dry-run) dry_run=(--dry-run); shift ;;
	-*) die "$1 is not an option" ;;
	*) [[ -z $version ]] || die "give one version"; version=$1; shift ;;
	esac
done
[[ -n $version ]] || die "say the version: deploy-control-plane.sh X.Y.Z"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$version is not a version (X.Y.Z)"

root=$(cd "$(dirname "$0")/../../../.." && pwd)
tag=v$version
head=$(git -C "$root" rev-parse HEAD)
at_tag=$(git -C "$root" rev-parse --verify --quiet "refs/tags/$tag^{commit}") ||
	die "there is no tag $tag here"
[[ $head == "$at_tag" ]] || die "$root is not at $tag; run this in the release's scratch worktree at the tag"
# An annotated tag's commit is its peeled line (^{}); a lightweight tag has only its own.
refs=$(git -C "$root" ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")
remote=$(awk '$2 ~ /\^\{\}$/ {print $1; exit}' <<<"$refs")
[[ -n $remote ]] || remote=$(awk 'NR == 1 {print $1}' <<<"$refs")
[[ -n $remote ]] || die "the tag $tag is not on origin"
[[ $remote == "$at_tag" ]] || die "the tag $tag on origin is not the one here"

cd "$root"
AGENTS_VERSION=$version exec deploy/gcp/up.sh ${dry_run[@]+"${dry_run[@]}"}
