#!/bin/sh
# The version of a checkout, in Semantic Versioning 2.0.0 (#1748, docs/explanation/versions.md).
#
#   on the tag vX.Y.Z        X.Y.Z
#   N commits after it       X.Y.(Z+1)-dev.N+g<sha>    sorts after X.Y.Z, as `git describe`'s
#                                                      X.Y.Z-N-g<sha> does not
#   with no such tag         0.0.1-dev.N+g<sha>
#
#   scripts/version.sh [-C <dir>]              the version
#   scripts/version.sh [-C <dir>] --marketing  X.Y.Z alone, for MARKETING_VERSION (Apple takes
#                                              digits and dots): the tag's, or X.Y.(Z+1) after it
#   scripts/version.sh --selftest              checks the above in a throwaway repository
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${1:-}" = -C ]; then
	root=$2
	shift 2
fi

selftest() {
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT INT TERM
	failed=0
	git -C "$work" init -q
	commit() { git -C "$work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
	expect() {
		got=$("$0" -C "$work" "$@" 2>&1) || true
		want=$(cat)
		if [ "$got" != "$want" ]; then
			echo "version.sh selftest: $* gave $got, want $want" >&2
			failed=1
		fi
	}
	commit one
	sha=$(git -C "$work" rev-parse --short=9 HEAD)
	expect <<-EOF
		0.0.1-dev.1+g$sha
	EOF
	git -C "$work" tag v0.6.0
	expect <<-EOF
		0.6.0
	EOF
	expect --marketing <<-EOF
		0.6.0
	EOF
	commit two
	commit three
	sha=$(git -C "$work" rev-parse --short=9 HEAD)
	expect <<-EOF
		0.6.1-dev.2+g$sha
	EOF
	expect --marketing <<-EOF
		0.6.1
	EOF
	# A tag that is not X.Y.Z (a release candidate) is not a version to count from.
	git -C "$work" tag v0.7.0-rc1
	expect <<-EOF
		0.6.1-dev.2+g$sha
	EOF
	[ "$failed" = 0 ] && echo "version.sh selftest: ok"
	return "$failed"
}

if [ "${1:-}" = --selftest ]; then
	selftest
	exit
fi

sha=$(git -C "$root" rev-parse --short=9 HEAD 2>/dev/null || echo unknown)
# The newest tag vX.Y.Z on HEAD's history, and how many commits since it.
tag=$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude 'v*-*' 2>/dev/null || true)
if [ -n "$tag" ]; then
	since=$(git -C "$root" rev-list --count "$tag..HEAD")
	base=${tag#v}
else
	since=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)
	base=0.0.0
fi
case $base in
*[!0-9.]* | *..* | .* | *.)
	echo "version.sh: $tag is not vX.Y.Z" >&2
	exit 1
	;;
esac
if [ "$since" = 0 ]; then
	echo "$base"
	exit
fi
major=${base%%.*}
rest=${base#*.}
minor=${rest%%.*}
patch=${rest#*.}
next="$major.$minor.$((patch + 1))"
if [ "${1:-}" = --marketing ]; then
	echo "$next"
else
	echo "$next-dev.$since+g$sha"
fi
