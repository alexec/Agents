#!/usr/bin/env bash
# Transfer a GitHub repo to an organisation by the API, with Alex's own gh (#5063, #4929).
#
#   scripts/github-transfer.sh [--dry-run] [--wait MINUTES] OWNER/REPO NEW_OWNER
#
# A transfer is hard to undo and moves every clone's remote, so a lane runs this only after
# Alex's yes for that repo, by a form. The script asks for nothing itself: the lane that runs
# it has the yes. `--dry-run` does only the checks and changes nothing.
#
# The checks, in order (GitHub's two conditions are admin on the repo and permission to make
# a repo in the organisation):
#   1. the token is an OAuth token with the `repo` scope;
#   2. the token's user is an admin of OWNER/REPO;
#   3. NEW_OWNER is an organisation, and the user is an active admin of it, or an active member
#      where members can make repos;
#   4. NEW_OWNER has no repo named REPO.
# Then `POST /repos/OWNER/REPO/transfer` (202: GitHub goes on in the background), then a wait
# until `GET /repos/NEW_OWNER/REPO` answers with that name (default 10 minutes).
#
# The credential is Alex's gh on this Mac, with GH_TOKEN and GITHUB_TOKEN unset: the agents'
# bot has no Administration permission (#4955). GH picks another gh (the self-test uses a
# fake one). No sudo is asked and no token is made.
set -euo pipefail

me=$(basename "$0")
die() { echo "$me: $*" >&2; exit 1; }
say() { echo "$me: $*"; }
lower() { printf "%s" "$1" | tr "[:upper:]" "[:lower:]"; }

usage() {
	sed -n '4p' "$0" | sed 's/^# *//' >&2
	exit 2
}

dry_run=0
wait_minutes=10
while [[ $# -gt 0 ]]; do
	case $1 in
	--dry-run) dry_run=1; shift ;;
	--wait) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || usage; wait_minutes=$2; shift 2 ;;
	-h | --help) usage ;;
	--) shift; break ;;
	-*) die "unknown option $1" ;;
	*) break ;;
	esac
done
[[ $# -eq 2 ]] || usage
src=$1 new_owner=$2
[[ $src =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "OWNER/REPO expected, got '$src'"
[[ $new_owner =~ ^[A-Za-z0-9-]+$ ]] || die "an organisation name expected, got '$new_owner'"
owner=${src%%/*} repo=${src#*/}
[[ $(lower "$owner") != "$(lower "$new_owner")" ]] || die "$src is already owned by $new_owner"

GH=${GH:-/usr/local/bin/gh}
[[ -x $GH ]] || die "no gh at $GH (set GH)"
gh_() { env -u GH_TOKEN -u GITHUB_TOKEN "$GH" "$@"; }

# 1. The token's scopes, from the X-OAuth-Scopes header.
headers=$(gh_ api -i user 2>/dev/null | tr -d '\r') || die "gh api user failed: is Alex's gh signed in? ($GH auth status)"
login=$(printf '%s\n' "$headers" | sed -n '/^{/,$p' | jq -r .login)
scopes=$(printf '%s\n' "$headers" | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | head -1)
[[ -n $scopes ]] || die "the token of $login lists no OAuth scopes: use Alex's own gh, not an App or fine-grained token"
[[ ",${scopes// /}," == *,repo,* ]] || die "the token of $login has no 'repo' scope (scopes: $scopes)"
say "token: $login, scopes $scopes"

# 2. Admin on the repo.
repo_json=$(gh_ api "repos/$src" 2>/dev/null) || die "$src: not found, or $login cannot see it"
full_name=$(jq -r .full_name <<<"$repo_json")
[[ $(lower "$full_name") == "$(lower "$src")" ]] || die "$src redirects to $full_name: transfer that name, or it moved already"
[[ $(jq -r .permissions.admin <<<"$repo_json") == true ]] || die "$login is not an admin of $src"
say "repo: $full_name, $login is admin"

# 3. The target is an organisation where the user can make repos.
type=$(gh_ api "users/$new_owner" --jq .type 2>/dev/null) || die "$new_owner: no such account"
[[ $type == Organization ]] || die "$new_owner is a $type, not an organisation"
membership=$(gh_ api "user/memberships/orgs/$new_owner" 2>/dev/null) || die "$login is not a member of $new_owner"
state=$(jq -r .state <<<"$membership") role=$(jq -r .role <<<"$membership")
[[ $state == active ]] || die "$login's membership of $new_owner is $state, not active"
if [[ $role != admin ]]; then
	can=$(gh_ api "orgs/$new_owner" --jq .members_can_create_repositories 2>/dev/null || echo false)
	[[ $can == true ]] || die "$login is a $role of $new_owner, and its members cannot make repos"
fi
say "organisation: $new_owner, $login is $role ($state)"

# 4. No repo of that name in the target. A 404 is what we want; anything else stops.
if target=$(gh_ api "repos/$new_owner/$repo" --jq .full_name 2>/dev/null); then
	die "$new_owner already has a repo named $repo ($target)"
fi
say "target: $new_owner/$repo is free"

if [[ $dry_run -eq 1 ]]; then
	say "dry run: all checks passed; $src was not transferred"
	exit 0
fi

# The transfer.
gh_ api -X POST "repos/$src/transfer" -f new_owner="$new_owner" --jq .full_name >/dev/null ||
	die "POST repos/$src/transfer failed"
say "transfer of $src to $new_owner asked (202); waiting up to $wait_minutes min"

deadline=$((SECONDS + wait_minutes * 60))
while ((SECONDS < deadline)); do
	if now=$(gh_ api "repos/$new_owner/$repo" --jq .full_name 2>/dev/null) &&
		[[ $(lower "$now") == "$(lower "$new_owner/$repo")" ]]; then
		say "done: $now"
		exit 0
	fi
	sleep "${GITHUB_TRANSFER_POLL:-10}"
done
die "$new_owner/$repo did not answer within $wait_minutes min; check https://github.com/$new_owner/$repo"
