#!/usr/bin/env bash
# Vets and tests, with -race as CI's `go` job does, only the Go packages this branch
# changes, so a lane finds a Go failure before it pushes and not in CI (#2994).
#
# A package is changed when a file in its folder under Go/ changed since the merge base
# with origin/main, committed or not (a testdata file counts for the package above it).
# A change to Go/go.mod, Go/go.sum or Packages/Wire (wiregen's source) runs ./... . No Go
# change: nothing runs. The container is Linux, so a failure only macOS has (CI's
# `go-darwin`) still shows only in CI.
#
# Lease "build" first. Usage: scripts/go-changed.sh [base]   (default origin/main)
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
base=$(git merge-base "${1:-origin/main}" HEAD)

changed=$( { git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)

if grep -qE '^(Go/go\.(mod|sum)|Packages/Wire/)' <<<"$changed"; then
	pkgs=(./...)
else
	pkgs=()
	# The package a testdata file belongs to is the folder above testdata; sort -u keeps
	# each folder once. A folder with no .go file left (all deleted) has nothing to test.
	for dir in $(grep -E '^Go/' <<<"$changed" | sed -e 's|/[^/]*$||' -e 's|/testdata.*||' | sort -u); do
		compgen -G "$dir/*.go" >/dev/null || continue
		pkgs+=("./${dir#Go/}")
	done
fi

if [ ${#pkgs[@]} -eq 0 ]; then
	echo "go-changed: no Go package changed since $(git rev-parse --short "$base")"
	exit 0
fi

echo "go-changed: ${pkgs[*]}"
Go/scripts/go.sh vet "${pkgs[@]}"
Go/scripts/go.sh test -race "${pkgs[@]}"
