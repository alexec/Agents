#!/usr/bin/env bash
# Keep only the cache just saved for this family and ref. Cache keys are immutable,
# so source changes otherwise leave every old build graph consuming repository quota.
set -euo pipefail

prefix=${1:?cache prefix required}
keep=${2:?current cache key required}
ref=${3:?Git ref required}

ids=$(gh cache list --key "$prefix" --ref "$ref" --limit 1000 --json id,key \
	| jq -r --arg keep "$keep" '.[] | select(.key != $keep) | .id') || {
	echo "::warning::Could not list caches to prune for $ref; leaving old entries in place."
	exit 0
}

while read -r id; do
	[[ -n $id ]] && gh cache delete "$id" || true
done <<< "$ids"
