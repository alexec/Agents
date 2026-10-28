#!/bin/zsh
# pr-shots.sh <pr> <png>... — put a UI enhancement's screenshots on the orphan branch
# `screenshots` as pr-<pr>/<file name>, and print the Markdown for the PR body (#2811).
# Name each file <client>-<state>.png (mac-empty.png, remote-question.png, web-error.png).
# It replaces every earlier shot of that PR, so a second round shows only the new set.
# It uses a temporary index and git plumbing: no checkout, no worktree, main gets no images.
set -euo pipefail

if (( $# < 2 )); then
  print -u2 "usage: pr-shots.sh <pr> <png>..."
  exit 2
fi
pr=$1; shift
[[ $pr == <-> ]] || { print -u2 "pr-shots: '$pr' is not a pull request number"; exit 2; }
for f in "$@"; do
  [[ -f $f && $f == *.png ]] || { print -u2 "pr-shots: $f is not a PNG file"; exit 2; }
done

branch=screenshots
repo=${PR_SHOTS_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
index=$(mktemp -t pr-shots)
trap 'rm -f "$index"' EXIT

for attempt in 1 2 3; do
  parent=()
  rm -f "$index"
  if git fetch -q origin "refs/heads/$branch" 2>/dev/null; then
    GIT_INDEX_FILE=$index git read-tree FETCH_HEAD
    parent=(-p "$(git rev-parse FETCH_HEAD)")
    GIT_INDEX_FILE=$index git rm -q -r --cached --ignore-unmatch "pr-$pr" >/dev/null
  else
    GIT_INDEX_FILE=$index git read-tree --empty
  fi
  for f in "$@"; do
    blob=$(git hash-object -w "$f")
    GIT_INDEX_FILE=$index git update-index --add --cacheinfo "100644,$blob,pr-$pr/${f:t}"
  done
  tree=$(GIT_INDEX_FILE=$index git write-tree)
  commit=$(git commit-tree "$tree" "${parent[@]}" -m "Screenshots for #$pr")
  if git push -q origin "${commit}:refs/heads/${branch}"; then
    for f in "$@"; do
      print "![${f:t:r}](https://github.com/$repo/blob/$branch/pr-$pr/${f:t}?raw=true)"
    done
    exit 0
  fi
  print -u2 "pr-shots: push $attempt lost a race, trying again"
done
print -u2 "pr-shots: could not push to $branch"
exit 1
