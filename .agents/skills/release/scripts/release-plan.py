#!/usr/bin/env python3
"""The next version and what goes into it (#914).

    release-plan.py            the last tag, the next version and every merged PR since
    release-plan.py --version  only the next version, e.g. 0.3.0 (nothing when nothing merged)
    release-plan.py --selftest

The version (Alex, 2026-10-13): minor (0.x+1.0) when a merged pull request since the last
tag is labelled `enhancement` or fixes an issue labelled `enhancement`; otherwise patch
(0.x.y+1). 1.0 and major versions only when Alex says, so this never makes one.

An enhancement counts only when its files change what a person gets (#2857): a client's UI,
the host or daemon, or the capability list (SEEN). An enhancement to release tooling,
workflows, skills or docs is listed as `[tooling]` and does not make a minor.

The open milestone (the earliest open one by the version its title starts with, #1340) has a
version too. When it differs from `next:`, the plan says why (#2779): an enhancement merged,
or a capability was removed, which a patch may not hold. The release skill then asks Alex.

The path (#2801) is the release skill's: `minor` (x.y.0) runs the reviews and checks, `patch`
(x.y.z, z > 0) skips them. It follows the open milestone's version, or `next:` with none open.

It reads origin/main and the v* tags (fetched first) and asks GitHub through `gh` for the
pull requests and their issues. It changes nothing.
"""
import importlib.util
import json
import pathlib
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


def path(version):
    """The release skill's path for a version (#2801): a patch skips the reviews and checks."""
    return "minor" if version.endswith(".0") else "patch"


def removed_capabilities(tag):
    path = pathlib.Path(__file__).with_name("capability-changes.py")
    spec = importlib.util.spec_from_file_location("capability_changes", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return sorted(module.at(tag)[0] - module.at("origin/main")[0])


def differs(version, planned, enhancements, removed):
    """Why the plan's version is not the milestone's, or None when they agree."""
    if version == planned:
        return None
    why = []
    if enhancements:
        why.append("enhancements merged")
    if removed:
        why.append("capabilities removed: " + ", ".join(removed))
    if not why:
        why.append("no enhancement merged" if key(version) < key(planned) else "the milestone is behind the tag")
    return f"plan v{version}, milestone v{planned} ({'; '.join(why)}); ask Alex which version"


def selftest():
    assert milestone_version("0.12.3 Bug fixes") == "0.12.3"
    assert milestone_version("0.13 Auto runtime and voice mode") == "0.13.0"
    assert milestone_version("1.0 Public release") == "1.0.0"
    assert milestone_version("Backlog") is None
    assert open_milestone(["0.15 Hosted", "1.0 Public release", "0.9 x", "0.12.3 Bug fixes", "Later"]) == ("0.9 x", "0.9.0")
    assert open_milestone(["0.13 A", "0.12.3 B"]) == ("0.12.3 B", "0.12.3")
    assert open_milestone([]) is None
    assert path("0.13.0") == "minor"
    assert path("0.12.3") == "patch"
    assert path("1.0.0") == "minor"
    assert seen(["Web/src/App.tsx", "docs/a.md"])
    assert seen(["Go/cmd/agentsd/main.go"])
    assert seen(["Packages/Wire/daemon.openrpc.json"])
    assert not seen([".agents/skills/release/SKILL.md", "AGENTS.md", "docs/reference/x.md"])
    assert not seen([".github/workflows/ci.yml", "scripts/lint.sh", "specs/071-web-remote/walks/parity.md"])
    assert not seen([])
    assert differs("0.12.0", "0.12.0", [1], []) is None
    assert differs("0.12.0", "0.11.2", [2700], ["files/1"]) == (
        "plan v0.12.0, milestone v0.11.2 (enhancements merged; capabilities removed: files/1); ask Alex which version")
    assert differs("0.11.2", "0.12.0", [], []) == (
        "plan v0.11.2, milestone v0.12.0 (no enhancement merged); ask Alex which version")
    print("release-plan selftest: ok")


def main():
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return
    only_version = "--version" in sys.argv[1:]
    run("git", "fetch", "--quiet", "--tags", "origin", "main")
    tag = last_tag()
    if tag is None:
        sys.exit("No vX.Y.Z tag on origin/main to count from.")
    since = run("git", "log", "-1", "--format=%cI", tag).strip()
    log = [line.split("\0", 1) for line in
           run("git", "log", "--format=%H%x00%s", f"{tag}..origin/main").splitlines()]
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

    def labels(item):
        return {l["name"] for l in item.get("labels", [])}

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

    version = bump(tag, bool(enhancements))
    if only_version:
        print(version)
        return
    why = (f"minor: enhancements {', '.join(f'#{n}' for n in enhancements[:8])}"
           f"{' …' if len(enhancements) > 8 else ''}") if enhancements else "patch: no enhancement merged"
    if tooling:
        why += f"; tooling only, not counted: {', '.join(f'#{n}' for n in tooling)}"
    milestone = open_milestone(run("gh", "api", "repos/{owner}/{repo}/milestones?state=open", "--paginate",
                                   "--jq", ".[].title").splitlines())
    print(f"last: {tag} ({since[:10]})")
    if milestone:
        title, planned = milestone
        print(f"next: v{version} ({why}); milestone: v{planned} ({title})")
        mismatch = differs(version, planned, enhancements, removed_capabilities(tag))
        if mismatch:
            print(f"differs: {mismatch}")
        print(f"path: {path(planned)} (the milestone's version)")
    else:
        print(f"next: v{version} ({why}); milestone: none open")
        print(f"path: {path(version)}")
    print(f"commits: {len(subjects)}, pull requests: {len(rows)}")
    print("pull requests:")
    for row in rows:
        print(f"  {row}")


if __name__ == "__main__":
    main()
