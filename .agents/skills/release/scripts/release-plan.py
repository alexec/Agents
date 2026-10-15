#!/usr/bin/env python3
"""The next version and what goes into it (#914).

    release-plan.py            the last tag, the next version and every merged PR since
    release-plan.py --version  only the next version, e.g. 0.3.0 (nothing when nothing merged)

The version (Alex, 2026-10-13): minor (0.x+1.0) when a merged pull request since the last
tag is labelled `enhancement` or fixes an issue labelled `enhancement`; otherwise patch
(0.x.y+1). 1.0 and major versions only when Alex says, so this never makes one.

It reads origin/main and the v* tags (fetched first) and asks GitHub through `gh` for the
pull requests and their issues. It changes nothing.
"""
import json
import re
import subprocess
import sys


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def gh_json(*args):
    return json.loads(run("gh", *args) or "[]")


def last_tag():
    tags = run("git", "tag", "--merged", "origin/main", "--list", "v*", "--sort=-v:refname").split()
    tags = [t for t in tags if re.fullmatch(r"v\d+\.\d+\.\d+", t)]
    return tags[0] if tags else None


def bump(tag, minor):
    major, mid, patch = (int(n) for n in tag[1:].split("."))
    return f"{major}.{mid + 1}.0" if minor else f"{major}.{mid}.{patch + 1}"


def main():
    only_version = "--version" in sys.argv[1:]
    run("git", "fetch", "--quiet", "--tags", "origin", "main")
    tag = last_tag()
    if tag is None:
        sys.exit("No vX.Y.Z tag on origin/main to count from.")
    since = run("git", "log", "-1", "--format=%cI", tag).strip()
    subjects = run("git", "log", "--format=%s", f"{tag}..origin/main").splitlines()
    if not subjects:
        if not only_version:
            print(f"last: {tag} ({since[:10]})\nnext: none, nothing merged since {tag}")
        return

    # A squash merge ends its subject with "(#PR)"; any "(#N)" before it names an issue.
    numbers = [re.findall(r"\(#(\d+)\)", s) for s in subjects]
    prs = {int(n[-1]) for n in numbers if n}

    merged = gh_json("pr", "list", "--state", "merged", "--base", "main", "--limit", "500",
                     "--search", f"merged:>={since[:10]}",
                     "--json", "number,title,labels,closingIssuesReferences")
    merged = [p for p in merged if p["number"] in prs]
    issues = {i["number"]: i for i in gh_json(
        "issue", "list", "--state", "all", "--limit", "1000",
        "--search", f"updated:>={since[:10]}", "--json", "number,labels,body")}

    def labels(item):
        return {l["name"] for l in item.get("labels", [])}

    rows, enhancements = [], []
    for pr in sorted(merged, key=lambda p: p["number"]):
        fixed = [i["number"] for i in pr.get("closingIssuesReferences") or []]
        is_enhancement = "enhancement" in labels(pr) or any(
            "enhancement" in labels(issues.get(n, {})) for n in fixed)
        if is_enhancement:
            enhancements.append(pr["number"])
        kind = "enhancement" if is_enhancement else "-"
        rows.append(f"#{pr['number']} [{kind}] {pr['title']} | issues: "
                    f"{', '.join(f'#{n}' for n in fixed) or '-'}")

    version = bump(tag, bool(enhancements))
    if only_version:
        print(version)
        return
    why = (f"minor: enhancements {', '.join(f'#{n}' for n in enhancements[:8])}"
           f"{' …' if len(enhancements) > 8 else ''}") if enhancements else "patch: no enhancement merged"
    print(f"last: {tag} ({since[:10]})")
    print(f"next: v{version} ({why})")
    print(f"commits: {len(subjects)}, pull requests: {len(rows)}")
    print("pull requests:")
    for row in rows:
        print(f"  {row}")


if __name__ == "__main__":
    main()
