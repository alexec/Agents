#!/bin/sh
# The ready-made workflows and skills (#5091) are in agentloops-dev/dotagents, not in agentsd.
# Each release pins one tag of it and that tag's commit (readyMadeTag and readyMadeCommit in
# Go/internal/agentsd/dotagents.go), and keeps a copy of that tag in
# Go/internal/agentsd/testdata/dotagents for the tests, which never use the network.
#
#   scripts/dotagents.sh pin <tag>   set the pin to <tag> and its commit, and write the copy
#   scripts/dotagents.sh check       fail when the copy is not the pinned tag's files, or the
#                                    tag is not the pinned commit
#
# DOTAGENTS_URL clones another repository (a fork, or a folder in a test). After `pin`, run
# agentsd's tests (scripts/go-changed.sh, under the "build" lease): they check that each skill
# names only the tools this release serves.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
go_file="$root/Go/internal/agentsd/dotagents.go"
copy="$root/Go/internal/agentsd/testdata/dotagents"
url=${DOTAGENTS_URL:-https://github.com/agentloops-dev/dotagents.git}

pinned() { sed -n "s/^[[:space:]]*$1[[:space:]]*= \"\(.*\)\"$/\1/p" "$go_file"; }

# fetch <tag> <dir>: a shallow clone of the tag into dir; it prints the commit.
fetch() {
	git -c advice.detachedHead=false clone -q --depth=1 --branch "$1" -- "$url" "$2"
	git -C "$2" rev-parse HEAD
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

case "${1:-}" in
pin)
	tag=${2:?usage: scripts/dotagents.sh pin <tag>}
	commit=$(fetch "$tag" "$tmp/d")
	rm -rf "$copy"
	mkdir -p "$copy"
	cp -R "$tmp/d/workflows" "$tmp/d/skills" "$copy/"
	sed -i.bak \
		-e "s/^\([[:space:]]*readyMadeTag[[:space:]]*= \)\".*\"$/\1\"$tag\"/" \
		-e "s/^\([[:space:]]*readyMadeCommit[[:space:]]*= \)\".*\"$/\1\"$commit\"/" "$go_file"
	rm -f "$go_file.bak"
	echo "dotagents: pinned $tag ($commit); the copy is in ${copy#"$root"/}"
	;;
check)
	tag=$(pinned readyMadeTag)
	want=$(pinned readyMadeCommit)
	if [ -z "$want" ]; then
		echo "dotagents: no commit is pinned: run scripts/dotagents.sh pin <tag>" >&2
		exit 1
	fi
	commit=$(fetch "$tag" "$tmp/d")
	if [ "$commit" != "$want" ]; then
		echo "dotagents: $tag is $commit, not the pinned $want: the tag moved" >&2
		exit 1
	fi
	mkdir -p "$tmp/want"
	cp -R "$tmp/d/workflows" "$tmp/d/skills" "$tmp/want/"
	if ! diff -r "$tmp/want" "$copy"; then
		echo "dotagents: the copy is not $tag: run scripts/dotagents.sh pin $tag" >&2
		exit 1
	fi
	echo "dotagents: the copy is $tag ($commit)"
	;;
*)
	echo "usage: scripts/dotagents.sh pin <tag> | check" >&2
	exit 2
	;;
esac
