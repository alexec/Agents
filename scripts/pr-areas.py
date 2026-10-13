#!/usr/bin/env python3
"""Map changed files to feature areas through .agents/areas (#873).

  scripts/pr-areas.py paths [PATH...]      the area of each path (stdin if none)
  scripts/pr-areas.py pr <n> [--apply]     a pull request's areas, and the other open
                                           pull requests that hold the same ones

`pr` reads the pull request's files with gh. With --apply it adds an `area:<name>`
label for each area (making the label if it is new). The CI step in
.github/workflows/areas.yml runs `pr <n> --apply` on every pull request.

Another open pull request holds an area when its own files are in it or it has the
label. A hold is a warning, never a failure: this script exits 0 unless it is used
wrongly, so a missing token or a fork's read-only token only costs the labels.
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AREAS_FILE = os.path.join(ROOT, ".agents", "areas")
LABEL_PREFIX = "area:"
LABEL_COLOUR = "c5def5"
IN_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"


def pattern_regex(pattern):
    """A path pattern as a regex: `**` crosses folders, `*` and `?` do not, and a
    trailing `/` takes everything under the folder."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    if pattern.endswith("/"):
        out.append(".*")
    return re.compile("".join(out) + r"\Z")


def load_rules(path=AREAS_FILE):
    rules = []
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                sys.exit(f"{path}:{number}: want '<pattern> <area>', got {line!r}")
            rules.append((pattern_regex(parts[0].lstrip("/")), parts[1]))
    return rules


def area_of(path, rules):
    """The area of one path: the last matching rule's, or None."""
    found = None
    for regex, area in rules:
        if regex.match(path):
            found = area
    return None if found in (None, "-") else found


def areas_of(paths, rules):
    return sorted({a for a in (area_of(p, rules) for p in paths) if a})


def gh(*args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"gh {' '.join(args)} failed")
    return result.stdout


def pr_files(number):
    # The REST list pages up to 3000 files; `gh pr view --json files` stops at 100.
    # A rename counts on both sides, so a move out of an area still holds it.
    out = gh("api", "--paginate", f"repos/{{owner}}/{{repo}}/pulls/{number}/files",
             "--jq", ".[] | .filename, (.previous_filename // empty)")
    return [line for line in out.splitlines() if line]


def warn(message, title="Area held"):
    print(f"::warning title={title}::{message}" if IN_ACTIONS else f"warning: {message}")


def summary(lines):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")


def apply_labels(number, areas):
    if not areas:
        return
    existing = set(json.loads(gh("label", "list", "--limit", "500", "--json", "name",
                                 "--jq", "[.[].name]")))
    for area in areas:
        name = LABEL_PREFIX + area
        if name not in existing:
            gh("label", "create", name, "--color", LABEL_COLOUR,
               "--description", f"Feature area {area} (.agents/areas, #873)")
    gh("pr", "edit", str(number), "--add-label", ",".join(LABEL_PREFIX + a for a in areas))


def run_pr(number, apply):
    rules = load_rules()
    mine = areas_of(pr_files(number), rules)
    print(f"#{number} areas: {', '.join(mine) or 'none'}")
    lines = [f"### Areas of #{number}", "", ", ".join(f"`{LABEL_PREFIX}{a}`" for a in mine) or "none"]

    if apply:
        try:
            apply_labels(number, mine)
        except RuntimeError as error:
            warn(f"could not label #{number}: {error}", "No area labels")

    if mine:
        others = json.loads(gh("pr", "list", "--state", "open", "--limit", "100",
                               "--json", "number,title,labels"))
        held = []
        for other in others:
            if other["number"] == number:
                continue
            theirs = {l["name"][len(LABEL_PREFIX):] for l in other["labels"]
                      if l["name"].startswith(LABEL_PREFIX)}
            theirs |= set(areas_of(pr_files(other["number"]), rules))
            for area in sorted(theirs.intersection(mine)):
                held.append(area)
                warn(f"area:{area} is also held by open PR #{other['number']} "
                     f"({other['title']}); land one before the other, or rebase after it.")
                lines.append(f"- ⚠️ `area:{area}` is also held by #{other['number']} {other['title']}")
        if not held:
            print("No other open pull request holds these areas.")
    summary(lines)


def main(argv):
    if len(argv) >= 2 and argv[1] == "paths":
        rules = load_rules()
        paths = argv[2:] or [l.strip() for l in sys.stdin if l.strip()]
        for path in paths:
            print(f"{path}\t{area_of(path, rules) or '-'}")
        return 0
    if len(argv) >= 3 and argv[1] == "pr" and argv[2].isdigit():
        try:
            run_pr(int(argv[2]), "--apply" in argv[3:])
        except RuntimeError as error:
            warn(f"could not read areas for #{argv[2]}: {error}", "No areas")
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
