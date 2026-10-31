#!/usr/bin/env python3
"""Score a pull request's risk from its file list and diff stats (#3040), modeled on
`pr-areas.py`.

  scripts/pr-risk.py pr <n> [--apply]   a pull request's risk score and breakdown

`pr` reads the pull request's files through `gh` (no model call: cheap and
deterministic, so it can run on every push without fighting `ci-speed`'s budget) and
scores it against four signals:

- size: lines changed (additions + deletions across all files).
- sensitive: touches a path in SENSITIVE_PATTERNS (security- or HADR-sensitive: auth,
  credentials, Keychain, CI/workflows, deploy secrets — see security-audit and
  hadr-review's SKILL.md).
- client UI: touches App/Sources, Remote/Sources, Shared/UI or Web/src (already needs
  Alex's approval when labelled `enhancement`, per #2811; this makes the same signal
  visible on bug fixes too).
- untested: touches product code but no test file.

A diff that only touches GENERATED_PATTERNS (Web/dist, generated.ts, a Go *_gen.go)
scores low regardless of size: generated output carries none of its own risk.

With --apply it replaces any existing `risk:*` label with the one this scores (making
the label if it is new) and posts or updates a single PR comment (found by its
`<!-- risk-check -->` marker) with the breakdown. v1 is report-only (#3040): this never
fails, blocks a merge or turns auto-merge off.
"""

import fnmatch
import json
import os
import subprocess
import sys

LABEL_COLOURS = {"risk:low": "c2e0c6", "risk:medium": "fbca04", "risk:high": "d93f0b"}
IN_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"
MARKER = "<!-- risk-check -->"

# Lines changed (additions + deletions): the size signal's points.
SIZE_THRESHOLDS = [(600, 3), (200, 2), (50, 1)]

# A match anywhere scores the sensitive signal: auth, credentials, Keychain, CI/supply
# chain and deploy secrets (security-audit, hadr-review SKILL.md; .agents/areas' build).
SENSITIVE_PATTERNS = [
    ".github/workflows/*",
    "scripts/release*.sh",
    "scripts/*secret*",
    "deploy/*",
    "*.entitlements",
    "Go/internal/controlplane/*",
    "Go/internal/controllink/*",
    "Go/internal/mac/signin/*",
    "Packages/AgentsKit/Sources/AgentsKitCore/Credentials/*",
    "Packages/AgentsKit/Sources/AgentsKitCore/Remote/*",
    "App/Sources/Settings/ServerCredentials.swift",
    "App/Sources/Hosts/Lending.swift",
    "*Keychain*",
]

# Client UI (#2811's own definition): the paths every UI-enhancement rule already names.
CLIENT_UI_PATTERNS = ["App/Sources/*", "Remote/Sources/*", "Shared/UI/*", "Web/src/*"]

# Generated output only: Web/dist and generated.ts (AGENTS.md, "Web/dist and
# generated.ts"), and a generated Go file.
GENERATED_PATTERNS = ["Web/dist/*", "Web/src/protocol/generated.ts", "Go/wire/*_gen.go"]

TEST_PATTERNS = [
    "*Tests.swift", "*Test.swift", "*/Tests/*", "test_*.py", "*_test.py", "*_test.go",
    "*.test.ts", "*.test.tsx", "Web/test/*",
]

# A file under one of these is product code: the untested signal only looks there, so a
# docs- or build-only PR with no tests does not score it.
CODE_PATTERNS = [
    "App/Sources/*", "Remote/Sources/*", "Shared/UI/*", "Web/src/*", "Go/*.go",
    "Packages/*/Sources/*",
]


def matches(path, patterns):
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def score_files(files):
    """files: a list of {"filename", "additions", "deletions"}. Returns (score, risk,
    lines explaining each signal that scored)."""
    paths = [f["filename"] for f in files]
    lines = []

    if paths and all(matches(p, GENERATED_PATTERNS) for p in paths):
        return 0, "risk:low", ["generated output only: " + ", ".join(sorted(paths))]

    score = 0

    changed = sum(f.get("additions", 0) + f.get("deletions", 0) for f in files)
    for threshold, points in SIZE_THRESHOLDS:
        if changed >= threshold:
            score += points
            lines.append(f"size: {changed} lines changed across {len(files)} file(s) (+{points})")
            break

    sensitive = sorted(p for p in paths if matches(p, SENSITIVE_PATTERNS))
    if sensitive:
        score += 3
        lines.append(f"touches a sensitive path: {', '.join(sensitive)} (+3)")

    ui = sorted(p for p in paths if matches(p, CLIENT_UI_PATTERNS))
    if ui:
        score += 1
        lines.append(f"touches client UI: {', '.join(ui)} (+1)")

    code_touched = any(matches(p, CODE_PATTERNS) for p in paths)
    tests_touched = any(matches(p, TEST_PATTERNS) for p in paths)
    if code_touched and not tests_touched:
        score += 1
        lines.append("touches product code with no test file changed (+1)")

    if score >= 5:
        risk = "risk:high"
    elif score >= 2:
        risk = "risk:medium"
    else:
        risk = "risk:low"
    return score, risk, lines


def gh(*args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"gh {' '.join(args)} failed")
    return result.stdout


def pr_files(number):
    # The REST list pages up to 3000 files; `gh pr view --json files` stops at 100.
    out = gh("api", "--paginate", f"repos/{{owner}}/{{repo}}/pulls/{number}/files",
             "--jq", ".[] | {filename, additions, deletions}")
    return [json.loads(line) for line in out.splitlines() if line]


def warn(message, title="Risk check"):
    print(f"::warning title={title}::{message}" if IN_ACTIONS else f"warning: {message}")


def apply_label(number, risk):
    existing = set(json.loads(gh("label", "list", "--limit", "500", "--json", "name",
                                 "--jq", "[.[].name]")))
    if risk not in existing:
        gh("label", "create", risk, "--color", LABEL_COLOURS[risk],
           "--description", "A pull request's scored risk (#3040); report-only, never a gate")
    current = json.loads(gh("pr", "view", str(number), "--json", "labels",
                             "--jq", "[.labels[].name]"))
    stale = [name for name in current if name.startswith("risk:") and name != risk]
    for name in stale:
        gh("pr", "edit", str(number), "--remove-label", name)
    if risk not in current:
        gh("pr", "edit", str(number), "--add-label", risk)


def upsert_comment(number, body):
    comments = json.loads(gh("pr", "view", str(number), "--json", "comments",
                              "--jq", "[.comments[] | {id: .id, body: .body}]"))
    existing = next((c for c in comments if MARKER in c["body"]), None)
    if existing:
        gh("api", "--method", "PATCH", f"repos/{{owner}}/{{repo}}/issues/comments/{existing['id']}",
           "-f", f"body={body}")
    else:
        gh("pr", "comment", str(number), "--body", body)


def run_pr(number, apply):
    files = pr_files(number)
    score, risk, lines = score_files(files)
    print(f"#{number} risk: {risk} (score {score})")
    for line in lines:
        print(f"  {line}")

    if not apply:
        return

    body = (
        f"{MARKER}\n<!-- agent -->\n### Risk: `{risk}`\n\n"
        + "\n".join(f"- {line}" for line in lines)
        + f"\n\nScore: {score}. Report-only (#3040): this never blocks a merge or turns "
        "auto-merge off."
    )
    try:
        apply_label(number, risk)
        upsert_comment(number, body)
    except RuntimeError as error:
        warn(f"could not label or comment on #{number}: {error}", "No risk label")


SELFTEST = [
    ([], (0, "risk:low", [])),
    ([{"filename": "Web/dist/app.js", "additions": 5000, "deletions": 0}],
     (0, "risk:low", ["generated output only: Web/dist/app.js"])),
    ([{"filename": "README.md", "additions": 3, "deletions": 1}],
     (0, "risk:low", [])),
    ([{"filename": "Go/internal/controlplane/service.go", "additions": 10, "deletions": 2}],
     (4, "risk:medium",
      ["touches a sensitive path: Go/internal/controlplane/service.go (+3)",
       "touches product code with no test file changed (+1)"])),
    ([{"filename": "App/Sources/Settings/ServerCredentials.swift", "additions": 400, "deletions": 300},
      {"filename": "Packages/AgentsKit/Tests/AgentsKitTests/CredentialStoreTests.swift",
       "additions": 20, "deletions": 0}],
     (7, "risk:high",
      ["size: 720 lines changed across 2 file(s) (+3)",
       "touches a sensitive path: App/Sources/Settings/ServerCredentials.swift (+3)",
       "touches client UI: App/Sources/Settings/ServerCredentials.swift (+1)"])),
    ([{"filename": "Web/src/views/Chat.tsx", "additions": 30, "deletions": 10},
      {"filename": "Web/test/chat.test.ts", "additions": 15, "deletions": 0}],
     (2, "risk:medium",
      ["size: 55 lines changed across 2 file(s) (+1)",
       "touches client UI: Web/src/views/Chat.tsx (+1)"])),
]


def selftest():
    failed = 0
    for files, want in SELFTEST:
        got = score_files(files)
        if got != want:
            failed += 1
            print(f"pr-risk selftest: want {want}, got {got} for {files}", file=sys.stderr)
    if failed:
        return 1
    print(f"pr-risk selftest: {len(SELFTEST)} case(s) passed.")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) >= 3 and argv[1] == "pr" and argv[2].isdigit():
        try:
            run_pr(int(argv[2]), "--apply" in argv[3:])
        except RuntimeError as error:
            warn(f"could not read files for #{argv[2]}: {error}", "No risk score")
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
