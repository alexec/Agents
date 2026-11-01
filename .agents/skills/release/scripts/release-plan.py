#!/usr/bin/env python3
"""The next version and what goes into it (#914).

    release-plan.py            the last tag, the next version and every merged PR since
    release-plan.py --version  only the next version, e.g. 0.3.0 (nothing when nothing merged)
    release-plan.py --ref <sha>  the same, up to the gate's commit instead of origin/main
    release-plan.py --after <sha>  whether a PR merged after the gate's commit makes it start over
    release-plan.py --selftest

The version (Alex, 2026-11-01, #3212): every release is a minor (0.x+1.0). There are no
patch releases or patch milestones any more (#3212 replaces #2801 and #2779). 1.0 and major versions
only when Alex says, so this never makes one.

An enhancement counts only when its files change what a person gets (#2857): a client's UI,
the host or daemon, or the capability list (SEEN). An enhancement to release tooling,
workflows, skills or docs is listed as `[tooling]`, so the notes put it under "Changed".

The open milestone (the earliest open one by the version its title starts with, #1340) has a
version too. When it differs from `next:`, the plan says why. The release skill then asks Alex.

The gate's commit (#3045) stays the same while lanes land after it: `--after` names only the
pull requests merged after it that fix a blocking issue (`priority:high`). Only those make the
gate start over on the newer main.

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


def bump(tag):
    """The next version after a tag: always the next minor (#3212)."""
    major, mid, _ = (int(n) for n in tag[1:].split("."))
    return f"{major}.{mid + 1}.0"


def milestone_version(title):
    """The version a milestone's title starts with: "0.13 Auto runtime" is 0.13.0."""
    m = re.match(r"v?(\d+)\.(\d+)(?:\.(\d+))?(?:\s|$)", title)
    return f"{m[1]}.{m[2]}.{m[3] or 0}" if m else None


# The paths of an enhancement that makes a minor (#2857): the clients, the host and daemon,
# and the capability list (capability-changes.py's documents).
SEEN = ("App/Sources/", "Remote/Sources/", "Shared/UI/", "Web/src/", "Go/", "Host/",
        "Packages/AgentsKit/Sources/", "Packages/Wire/daemon.openrpc.json",
        "Packages/Wire/control.openrpc.json")


def seen(files):
    """Whether a change to these files is one a person gets."""
    return any(f.startswith(SEEN) for f in files)


def key(version):
    return tuple(int(n) for n in version.split("."))


def open_milestone(titles):
    """The earliest open milestone as (title, version), or None."""
    found = sorted(((milestone_version(t), t) for t in titles if milestone_version(t)), key=lambda vt: key(vt[0]))
    return (found[0][1], found[0][0]) if found else None


def differs(version, planned):
    """Why the plan's version is not the milestone's, or None when they agree."""
    if version == planned:
        return None
    why = "the milestone is ahead of the tag" if key(version) < key(planned) else "the milestone is behind the tag"
    return f"plan v{version}, milestone v{planned} ({why}); ask Alex which version"


def blocking(labels):
    """Whether an issue with these labels holds the release, so its fix must be in the tag (#3045)."""
    return "priority:high" in labels


def selftest():
    assert milestone_version("0.12.3 Bug fixes") == "0.12.3"
    assert milestone_version("0.13 Auto runtime and voice mode") == "0.13.0"
    assert milestone_version("1.0 Public release") == "1.0.0"
    assert milestone_version("Backlog") is None
    assert open_milestone(["0.15 Hosted", "1.0 Public release", "0.9 x", "0.12.3 Bug fixes", "Later"]) == ("0.9 x", "0.9.0")
    assert open_milestone(["0.13 A", "0.12.3 B"]) == ("0.12.3 B", "0.12.3")
    assert open_milestone([]) is None
    assert bump("v0.15.0") == "0.16.0"
    assert bump("v0.14.1") == "0.15.0"
    assert seen(["Web/src/App.tsx", "docs/a.md"])
    assert seen(["Go/cmd/agentsd/main.go"])
    assert seen(["Packages/Wire/daemon.openrpc.json"])
    assert not seen([".agents/skills/release/SKILL.md", "AGENTS.md", "docs/reference/x.md"])
    assert not seen([".github/workflows/ci.yml", "scripts/lint.sh", "specs/071-web-remote/walks/parity.md"])
    assert not seen([])
    assert differs("0.16.0", "0.16.0") is None
    assert differs("0.16.0", "0.15.1") == (
        "plan v0.16.0, milestone v0.15.1 (the milestone is behind the tag); ask Alex which version")
    assert differs("0.16.0", "0.17.0") == (
        "plan v0.16.0, milestone v0.17.0 (the milestone is ahead of the tag); ask Alex which version")
    assert blocking({"bug", "priority:high"})
    assert blocking({"priority:high"})
    assert not blocking({"bug", "priority:medium"})
    assert not blocking({"bug", "priority:low"})
    assert not blocking(set())
    print("release-plan selftest: ok")


def option(name):
    args = sys.argv[1:]
    if name not in args:
        return None
    i = args.index(name)
    if i + 1 >= len(args):
        sys.exit(f"{name} needs a commit")
    return run("git", "rev-parse", "--verify", f"{args[i + 1]}^{{commit}}").strip()


def labels(item):
    return {l["name"] for l in item.get("labels", [])}


def after(pin):
    """The PRs merged to origin/main after the gate's commit that fix a blocking issue (#3045)."""
    if subprocess.run(["git", "merge-base", "--is-ancestor", pin, "origin/main"]).returncode != 0:
        sys.exit(f"{pin[:12]} is not on origin/main")
    subjects = run("git", "log", "--format=%s", f"{pin}..origin/main").splitlines()
    prs = {int(n[-1]) for n in (re.findall(r"\(#(\d+)\)", s) for s in subjects) if n}
    print(f"pin: {pin[:12]}; merged after it: {len(subjects)} commits, {len(prs)} pull requests")
    restart = []
    for pr in sorted(prs):
        fixed = gh_json("pr", "view", str(pr), "--json", "closingIssuesReferences",
                        "--jq", "[.closingIssuesReferences[].number]")
        for n in fixed:
            issue = gh_json("issue", "view", str(n), "--json", "labels")
            if blocking(labels(issue)):
                restart.append(f"#{pr} fixes #{n} ({', '.join(sorted(l for l in labels(issue) if l.startswith('priority:')))})")
    for line in restart:
        print(f"restart: {line}")
    print("verdict: start over on origin/main" if restart else "verdict: keep the pin")


def main():
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return
    only_version = "--version" in sys.argv[1:]
    run("git", "fetch", "--quiet", "--tags", "origin", "main")
    pin = option("--after")
    if pin:
        after(pin)
        return
    ref = option("--ref") or "origin/main"
    tag = last_tag()
    if tag is None:
        sys.exit("No vX.Y.Z tag on origin/main to count from.")
    since = run("git", "log", "-1", "--format=%cI", tag).strip()
    log = [line.split("\0", 1) for line in
           run("git", "log", "--format=%H%x00%s", f"{tag}..{ref}").splitlines()]
    subjects = [s for _, s in log]
    if not subjects:
        if not only_version:
            print(f"last: {tag} ({since[:10]})\nnext: none, nothing merged since {tag}")
        return

    # A squash merge ends its subject with "(#PR)"; any "(#N)" before it names an issue.
    numbers = [re.findall(r"\(#(\d+)\)", s) for s in subjects]
    commits = {int(n[-1]): sha for n, (sha, _) in zip(numbers, log) if n}
    prs = set(commits)

    def files(pr):
        return run("git", "diff-tree", "--no-commit-id", "--name-only", "-r", commits[pr]).splitlines()

    merged = gh_json("pr", "list", "--state", "merged", "--base", "main", "--limit", "500",
                     "--search", f"merged:>={since[:10]}",
                     "--json", "number,title,labels,closingIssuesReferences")
    merged = [p for p in merged if p["number"] in prs]
    issues = {i["number"]: i for i in gh_json(
        "issue", "list", "--state", "all", "--limit", "1000",
        "--search", f"updated:>={since[:10]}", "--json", "number,labels")}

    rows, enhancements, tooling = [], [], []
    for pr in sorted(merged, key=lambda p: p["number"]):
        fixed = [i["number"] for i in pr.get("closingIssuesReferences") or []]
        is_enhancement = "enhancement" in labels(pr) or any(
            "enhancement" in labels(issues.get(n, {})) for n in fixed)
        is_tooling = is_enhancement and not seen(files(pr["number"]))
        if is_tooling:
            tooling.append(pr["number"])
        elif is_enhancement:
            enhancements.append(pr["number"])
        is_bug = "bug" in labels(pr) or any("bug" in labels(issues.get(n, {})) for n in fixed)
        kind = "tooling" if is_tooling else "enhancement" if is_enhancement else "bug" if is_bug else "-"
        rows.append(f"#{pr['number']} [{kind}] {pr['title']} | issues: "
                    f"{', '.join(f'#{n}' for n in fixed) or '-'}")

    version = bump(tag)
    if only_version:
        print(version)
        return
    why = (f"enhancements {', '.join(f'#{n}' for n in enhancements[:8])}"
           f"{' …' if len(enhancements) > 8 else ''}") if enhancements else "no enhancement merged"
    if tooling:
        why += f"; tooling: {', '.join(f'#{n}' for n in tooling)}"
    milestone = open_milestone(run("gh", "api", "repos/{owner}/{repo}/milestones?state=open", "--paginate",
                                   "--jq", ".[].title").splitlines())
    print(f"last: {tag} ({since[:10]})")
    if milestone:
        title, planned = milestone
        print(f"next: v{version} ({why}); milestone: v{planned} ({title})")
        mismatch = differs(version, planned)
        if mismatch:
            print(f"differs: {mismatch}")
    else:
        print(f"next: v{version} ({why}); milestone: none open")
    print(f"commits: {len(subjects)}, pull requests: {len(rows)}")
    print("pull requests:")
    for row in rows:
        print(f"  {row}")


if __name__ == "__main__":
    main()
