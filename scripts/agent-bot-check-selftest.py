#!/usr/bin/env python3
"""Tests the agent bot check (#3859) against a fake GitHub API.

The check's script is in `.github/workflows/agent-bot-check.yml`, so that a repository
that calls it pins one ref and checks out nothing. This takes the script out of that
file's `python3 - <<'PY'` step and runs each case through its `check()`.
"""
import base64
import pathlib
import sys
import textwrap

root = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = root / ".github" / "workflows" / "agent-bot-check.yml"
REPO = "acme/app"
BOT = "alexec-agents[bot]"

CONFIG = f"bots:\n  {BOT}: alexec  # the owner\n"
ONE_PERSON = CONFIG + "require-another-approver: false\n"


def load():
    text = WORKFLOW.read_text()
    start = text.index("python3 - <<'PY'\n") + len("python3 - <<'PY'\n")
    end = text.index("\n          PY\n", start)
    source = textwrap.dedent(text[start:end])
    module = {"__name__": "agent_bot_check"}
    exec(compile(source, str(WORKFLOW), "exec"), module)
    return module


def review(login, state, kind="User"):
    return {"user": {"login": login, "type": kind}, "state": state}


def fake(config=CONFIG, permission="write", reviews=()):
    def api(path, pages=False):
        if path.startswith(f"repos/{REPO}/contents/.github/agent-bots.yml?ref=main"):
            return None if config is None else {"content": base64.b64encode(config.encode()).decode()}
        if path == f"repos/{REPO}/collaborators/alexec/permission":
            return None if permission is None else {"permission": permission}
        if path.startswith(f"repos/{REPO}/pulls/7/reviews"):
            assert pages
            return list(reviews)
        raise AssertionError(f"unexpected read: {path}")
    return api


def main():
    check = load()["check"]
    cases = [
        ("owner with write access passes", fake(), BOT, True),
        ("owner with admin access passes", fake(permission="admin"), BOT, True),
        ("owner removed fails", fake(permission=None), BOT, False),
        ("owner with read access fails", fake(permission="read"), BOT, False),
        ("owner as the only approver fails", fake(reviews=[review("alexec", "APPROVED")]), BOT, False),
        ("owner plus another approver passes",
         fake(reviews=[review("alexec", "APPROVED"), review("sam", "APPROVED")]), BOT, True),
        ("another approver alone passes", fake(reviews=[review("sam", "APPROVED")]), BOT, True),
        ("no approval yet passes", fake(), BOT, True),
        ("a bot's approval never counts",
         fake(reviews=[review("alexec", "APPROVED"), review("helper[bot]", "APPROVED", "Bot")]), BOT, False),
        ("a dismissed approval no longer counts",
         fake(reviews=[review("alexec", "APPROVED"), review("sam", "APPROVED"), review("sam", "DISMISSED")]),
         BOT, False),
        ("a comment keeps an earlier approval",
         fake(reviews=[review("alexec", "APPROVED"), review("sam", "APPROVED"), review("sam", "COMMENTED")]),
         BOT, True),
        ("rule 2 turned off passes",
         fake(config=ONE_PERSON, reviews=[review("alexec", "APPROVED")]), BOT, True),
        ("rule 2 turned off still checks access", fake(config=ONE_PERSON, permission="read"), BOT, False),
        ("a person's pull request passes", fake(), "sam", True),
        ("no agent-bots.yml passes", fake(config=None), BOT, True),
    ]
    failed = 0
    for name, api, author, want in cases:
        passed, message = check(api, REPO, 7, author, "main")
        if passed != want:
            failed += 1
            print(f"FAIL {name}: passed={passed}, want {want}: {message}")
    for name, text in [("unknown key", "bots:\nowners: x\n"), ("bad flag", "require-another-approver: maybe\n")]:
        try:
            check(fake(config=text), REPO, 7, BOT, "main")
        except ValueError:
            continue
        failed += 1
        print(f"FAIL a config with a {name} is an error")
    if failed:
        return 1
    print(f"agent-bot-check: {len(cases) + 2} cases pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
