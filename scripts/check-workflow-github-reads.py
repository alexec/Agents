#!/usr/bin/env python3
"""A workflow that runs with no card to ask reads only this repo's own pull requests.

Anyone on GitHub can open a pull request from a fork, and its title, branch name and CI
logs are theirs. This reads `.agents/workflows/*.md` and, for each one whose
`permission-mode` is `auto` or `bypassPermissions`, fails on:

- a `gh pr list` that asks for `title`, `headRefName` or `body` without `isCrossRepository`;
- a `gh run list --branch`, which puts a branch name on a command line.

`--selftest` checks the check.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent

LOOSE = re.compile(r"^permission-mode:\s*(auto|bypassPermissions)\s*$", re.M)
PR_LIST = re.compile(r"gh pr list[^`\n]*")
STRANGER_TEXT = re.compile(r"\b(title|headRefName|body)\b")
RUN_BY_BRANCH = re.compile(r"gh run list[^`\n]*(--branch|-b )")


def problems(name, text):
    found = []
    front = text.split("\n---", 1)[0] if text.startswith("---") else ""
    if not LOOSE.search(front):
        return found
    for number, line in enumerate(text.splitlines(), 1):
        for command in PR_LIST.findall(line):
            if STRANGER_TEXT.search(command) and "isCrossRepository" not in command:
                found.append(f"{name}:{number}: a gh pr list that reads fork pull requests' text: {command}")
        if RUN_BY_BRANCH.search(line):
            found.append(f"{name}:{number}: a gh run list by branch name: {line.strip()}")
    return found


def selftest():
    loose = "---\nname: x\npermission-mode: auto\n---\n"
    cases = [
        (loose + "`gh pr list --json number,title,headRefName`\n", 1),
        (loose + "`gh pr list --json number,title,isCrossRepository`\n", 0),
        (loose + "`gh pr list --state open --json number,labels`\n", 0),
        (loose + "`gh run list --branch <headRefName> --workflow ci.yml`\n", 1),
        (loose + "`gh run list --commit <headRefOid> --workflow ci.yml`\n", 0),
        ("---\nname: x\npermission-mode: default\n---\n`gh pr list --json title`\n", 0),
    ]
    failed = 0
    for text, want in cases:
        got = len(problems("case", text))
        if got != want:
            print(f"selftest: want {want} problem(s), got {got}, in:\n{text}", file=sys.stderr)
            failed += 1
    if failed:
        return 1
    print("check-workflow-github-reads selftest passes.")
    return 0


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    found = []
    for path in sorted((root / ".agents" / "workflows").glob("*.md")):
        found += problems(str(path.relative_to(root)), path.read_text())
    for problem in found:
        print(problem)
    if found:
        print(f"\n{len(found)} line(s) let a workflow with no card read text from strangers' "
              "pull requests. Keep the rows whose isCrossRepository is false, and find runs by commit.",
              file=sys.stderr)
        return 1
    print("Every workflow with no card reads only this repo's own pull requests.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
