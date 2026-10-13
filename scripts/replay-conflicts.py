#!/usr/bin/env python3
"""Count the merge conflicts pull requests met, to see whether areas help (#873).

  scripts/replay-conflicts.py [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--last N]

For each pull request merged in the window (the last 150 by default), every force-push
is replayed: the head from before the push is merged against main as it was at the time
of the push. If that merge conflicts, the push was a rebase the lane had to do. Each open
pull request's head is also merged against main now. Merges are done with
`git merge-tree`, so nothing in the working tree changes.

The report gives each conflict with its files and their areas (.agents/areas), then the
total, and the conflicts by area. 10–13 October 2026, before areas: 30 conflicts in
150 pull requests (28 rebases, 2 open).
"""

import argparse
import json
import os
import subprocess
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module  # noqa: E402

areas = import_module("pr-areas")

QUERY = """
query($owner: String!, $repo: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      timelineItems(itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT], first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { ... on HeadRefForcePushedEvent {
          createdAt beforeCommit { oid } afterCommit { oid } } }
      }
    }
  }
}
"""


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    return result


def gh_json(*args):
    return json.loads(areas.gh(*args))


def force_pushes(owner, repo, number):
    pushes, after = [], None
    while True:
        args = ["api", "graphql", "-f", f"query={QUERY}", "-f", f"owner={owner}",
                "-f", f"repo={repo}", "-F", f"number={number}"]
        if after:
            args += ["-f", f"after={after}"]
        items = gh_json(*args)["data"]["repository"]["pullRequest"]["timelineItems"]
        pushes += [n for n in items["nodes"] if n.get("beforeCommit")]
        if not items["pageInfo"]["hasNextPage"]:
            return pushes
        after = items["pageInfo"]["endCursor"]


def have(sha):
    if git("cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0:
        return True
    # GitHub serves a force-pushed-away commit by its id for a while, not for ever.
    return git("fetch", "-q", "origin", sha, check=False).returncode == 0


def main_at(when):
    out = git("rev-list", "-1", "--first-parent", f"--before={when}", "origin/main").stdout
    return out.strip()


def conflicts(main, head):
    """The files a merge of head into main conflicts in; empty when it merges."""
    result = git("merge-tree", "--write-tree", "--name-only", "--no-messages", main, head,
                 check=False)
    if result.returncode == 0:
        return []
    if result.returncode != 1:
        raise RuntimeError(result.stderr.strip())
    return [line for line in result.stdout.splitlines()[1:] if line]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--since", help="merged on or after this date")
    parser.add_argument("--until", help="merged on or before this date")
    parser.add_argument("--last", type=int, default=150, help="at most this many merged PRs")
    options = parser.parse_args()

    owner, repo = gh_json("repo", "view", "--json", "owner,name", "--jq",
                          "[.owner.login, .name]")
    git("fetch", "-q", "origin", "main")
    rules = areas.load_rules()

    search = []
    if options.since or options.until:
        search = ["--search", f"merged:{options.since or '*'}..{options.until or '*'}"]
    merged = gh_json("pr", "list", "--state", "merged", "--limit", str(options.last),
                     "--json", "number,title,mergedAt", *search)
    opened = gh_json("pr", "list", "--state", "open", "--limit", "100",
                     "--json", "number,title,headRefOid")

    found, skipped = [], 0
    for pr in sorted(merged, key=lambda p: p["mergedAt"]):
        for push in force_pushes(owner, repo, pr["number"]):
            before = push["beforeCommit"]["oid"]
            if not have(before):
                skipped += 1
                continue
            files = conflicts(main_at(push["createdAt"]), before)
            if files:
                found.append(("rebase", pr, push["createdAt"], files))
    for pr in opened:
        if have(pr["headRefOid"]):
            files = conflicts("origin/main", pr["headRefOid"])
            if files:
                found.append(("open", pr, "now", files))

    by_area = Counter()
    for kind, pr, when, files in found:
        held = areas.areas_of(files, rules)
        by_area.update(held or ["(none)"])
        print(f"#{pr['number']} {kind} {when}: {pr['title']}")
        for path in files:
            print(f"    {path}  [{areas.area_of(path, rules) or '-'}]")

    rebases = sum(1 for f in found if f[0] == "rebase")
    print()
    print(f"{len(found)} conflicts in {len(merged)} merged PRs and {len(opened)} open: "
          f"{rebases} rebases, {len(found) - rebases} open now.")
    if skipped:
        print(f"{skipped} force-pushes skipped: GitHub no longer serves their old head.")
    print("By area: " + ", ".join(f"{a} {n}" for a, n in by_area.most_common()))
    print("Before areas (10–13 October 2026): 30 conflicts in 150 merged PRs.")


if __name__ == "__main__":
    main()
