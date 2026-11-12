#!/usr/bin/env python3
"""Approval cards use only the approval words (#4263).

Every approval a person gives an agent says Approve, Approve for This Session, Always
Approve, Approve for 1 Hour or Deny, on the Mac window, the Remote, the web page, in
notifications and in agentsd's replies to the agent (docs/reference/approval-words.md).

This reads the clients' copy (App/Sources, Remote/Sources, Shared/UI, Web/src,
Packages/AgentsKit/Sources) and agentsd (Go/internal/agentsd, Go/internal/policylayers),
and fails on a string literal or a button's text that is one of the old words: Allow Once,
Allow for This Session, Allow Always, Allow for 1 Hour, Refuse, Reject or Yes to all.
Words a runtime sends (its own permission options) come over the wire, not from this
copy, so they are not checked. A line that must keep one says so with
`// approval-words: <why>`.
"""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent

PATHS = ["App/Sources", "Remote/Sources", "Shared/UI", "Web/src", "Packages/AgentsKit/Sources",
         "Go/internal/agentsd", "Go/internal/policylayers"]
SUFFIXES = {".swift", ".ts", ".tsx", ".go"}
OLD = r"(Allow Once|Allow for This Session|Allow Always|Allow for 1 Hour|Refuse|Reject|Yes to all)"
# The whole literal, "…" or `…`, or a button's text, >…<.
WORD = re.compile(r"([\"`>])" + OLD + r"([\"`<])")


def problems_in(text):
    found = []
    for number, line in enumerate(text.splitlines()):
        if "approval-words:" in line:
            continue
        for m in WORD.finditer(line):
            opening, closing = m.group(1), m.group(3)
            if (opening == ">") != (closing == "<"):
                continue
            found.append((number + 1, m.group(2)))
    return found


SELFTEST = [
    ('Button("Allow Once") { }', ["Allow Once"]),
    ('<button onClick={no}>Refuse</button>', ["Refuse"]),
    ('alwaysApprove: "Yes to all",', ["Yes to all"]),
    ('kind === "deploy" ? "Reject" : "Deny"', ["Reject"]),
    ('Name: "Refuse", Kind: sdk.PermissionOptionKindRejectOnce', ["Refuse"]),
    # The new words, and the old ones inside a longer sentence or a name, pass.
    ('Button("Approve") { }; "Always Approve"; "Deny"', []),
    ('// Allow Once was the old word', []),
    ('Text("Refuse agents on machines that do not follow the policy")', []),
    ('func walkRefuseMicrophone()', []),
    ('return "Refuse" // approval-words: the policy file\'s own value', []),
]


def selftest():
    bad = 0
    for text, want in SELFTEST:
        got = [w for _, w in problems_in(text)]
        if got != want:
            print(f"check-approval-words selftest: {text!r}: got {got}, want {want}", file=sys.stderr)
            bad += 1
    return bad


def main():
    if "--selftest" in sys.argv[1:]:
        return 1 if selftest() else 0
    files = subprocess.run(["git", "ls-files", "--", *PATHS], cwd=root, capture_output=True,
                           text=True, check=True).stdout.split()
    status = 0
    for name in files:
        path = root / name
        if path.suffix not in SUFFIXES or name.endswith("_test.go") or "generated" in path.name \
                or name.endswith("_gen.go") or not path.is_file():
            continue
        for number, word in problems_in(path.read_text(encoding="utf-8")):
            print(f"{name}:{number}: \"{word}\" is an old approval word; "
                  "use Approve, Approve for This Session, Always Approve, Approve for 1 Hour or Deny "
                  "(docs/reference/approval-words.md)")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
