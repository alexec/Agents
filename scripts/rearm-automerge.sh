#!/usr/bin/env bash
# Turn a pull request's auto-merge off and on again (#1741).
#
#   scripts/rearm-automerge.sh PR...                re-arm these PRs now
#   scripts/rearm-automerge.sh --stalled [MINUTES]  re-arm, once per head, every open PR that is
#                                                   CLEAN with auto-merge on and has been for
#                                                   MINUTES (default 10); says so in a PR comment
#
# GitHub can leave auto-merge armed on a PR that is CLEAN and green and never merge it. On
# 2026-10-20 it did so three times (#1638, #1642, #1735): auto-merge was turned on while the
# PR's base had just moved (a stack landing bottom-up, so GitHub retargeted the next PR to
# main), and the last required check going green did not merge it. Turning auto-merge off
# and on again merged each one within four seconds.
#
# So a lane runs `scripts/rearm-automerge.sh <pr>` after it changes a PR's base, or after it
# turns auto-merge on for a PR whose base just moved. A landing lane runs `--stalled` to catch
# the ones nobody re-armed. `--stalled` re-arms a PR only once per head commit; a PR it has
# re-armed before at the same head is listed for a person to look at.
#
# A PR labelled `hold:v*` waits for that release to ship (#2931): this script never arms it.
# Only the release takes the label off and turns auto-merge on. Since #3212 there are no patch
# milestones, so nothing labels a PR this way as a rule; a hold set by hand still works.
#
# GH_REPO picks the repository, as for gh; by default it is this checkout's.
set -euo pipefail

me=$(basename "$0")
die() { echo "$me: $*" >&2; exit 1; }

# The labels on a PR that start with `hold:v`, one per line.
holds() {
	gh pr view "$1" --json labels --jq '.labels[].name | select(startswith("hold:v"))'
}

# The repository only allows squash merges.
rearm() {
	local pr=$1 held
	held=$(holds "$pr")
	if [[ -n $held ]]; then
		echo "$me: #$pr is labelled ${held//$'\n'/, }: it waits for that release, so it is not armed (#2931)" >&2
		return 1
	fi
	gh pr merge "$pr" --disable-auto >/dev/null 2>&1 || true
	gh pr merge "$pr" --auto --squash >/dev/null || die "could not turn auto-merge on again for #$pr"
	echo "$me: re-armed auto-merge on #$pr"
}

# One line per open PR with auto-merge on: number, merge state, head sha, and the minutes
# since the latest of: auto-merge turned on, any check on the head finishing.
open_auto_prs() {
	gh pr list --state open --limit 200 \
		--json number,mergeStateStatus,headRefOid,autoMergeRequest,statusCheckRollup \
		--jq '.[] | select(.autoMergeRequest != null)
			| ([.autoMergeRequest.enabledAt]
				+ [.statusCheckRollup[]? | (.completedAt // .createdAt // empty)
					| select(startswith("0001-") | not)]
				| map(sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | max) as $since
			| [.number, .mergeStateStatus, .headRefOid, (((now - $since) / 60) | floor)]
			| @tsv'
}

stalled() {
	local minutes=${1:-10}
	[[ $minutes =~ ^[0-9]+$ ]] || die "MINUTES must be a whole number, not '$minutes'"
	local found=0 pr state head age marker
	while IFS=$'\t' read -r pr state head age; do
		[[ -n $pr && $state == CLEAN && $age -ge $minutes ]] || continue
		found=1
		marker="<!-- rearm-automerge $head -->"
		if gh pr view "$pr" --json comments --jq '.comments[].body' | grep -qF -- "$marker"; then
			echo "$me: #$pr is still CLEAN and unmerged ${age}m on, after a re-arm at this head: a person should look"
			continue
		fi
		rearm "$pr" || continue
		gh pr comment "$pr" --body "Auto-merge re-armed by \`scripts/rearm-automerge.sh --stalled\`: this PR was CLEAN with auto-merge on for ${age} minutes and had not merged (#1741).

$marker" >/dev/null
	done < <(open_auto_prs)
	[[ $found == 1 ]] || echo "$me: no PR is CLEAN with auto-merge on for ${minutes}m or more"
}

[[ $# -gt 0 ]] || die "usage: $me PR... | --stalled [MINUTES]"
if [[ $1 == --stalled ]]; then
	stalled "${2:-10}"
	exit 0
fi
status=0
for pr in "$@"; do
	[[ $pr =~ ^[0-9]+$ ]] || die "not a PR number: '$pr'"
	rearm "$pr" || status=1
done
exit "$status"
