"""Agents do your GitHub work (#5076): Sam labels an issue, Work an issue opens a pull request,
Fix failed checks makes the red check green, Address review comments answers Sam's comment and
CodeRabbit's, Sam merges, and the pull request says what the work cost.

The script, approved by Alex on 2026-11-12, is specs/4832-videos/scripts/github.md (#5075).
The repository is a real one on github.com (REPO below), reset by `reset(v)` before each take;
its owner is Sam's demo account, never Alex's (Alex, 2026-11-12, by form)."""
import os

GROUP = "marketing"
LAYOUT = "mac"
TITLE = "Agents do your GitHub work"
WINDOW = (1360, 820)
DOCS = "how-to/use-github/"  # the docs page, on docs.agentloops.dev (upload.py)

# The demo repository, on Sam's demo account agentloops-dev-agent (#5076; Alex made the
# account by hand). AGENTS_VIDEO_GITHUB_REPO overrides it.
REPO = os.environ.get("AGENTS_VIDEO_GITHUB_REPO", "agentloops-dev-agent/weather")
ISSUE_TITLE = "Show the low in Celsius too"
REVIEW_COMMENT = "Round the low to one decimal, please."

# Directed lines (voice.py, #4964, #5079), word for word from the approved script.
LINES = {
    "intro": '<speak style="warm">Sam has work on GitHub.<break time="450ms"/>Today,'
             '<break time="150ms"/>agents do it,<break time="200ms"/>and Sam just watches.</speak>',
    "label": '<speak style="calm">To hand an issue to an agent,<break time="200ms"/>Sam gives it the '
             '<emphasis>agent</emphasis> label.<break time="450ms"/>That\'s all Sam does.</speak>',
    "start": '<speak style="calm">The <emphasis>Work an issue</emphasis> workflow sees the label,'
             '<break time="200ms"/>and starts an agent on a branch of its own.</speak>',
    "pr": '<speak style="calm">It reads the issue,<break time="150ms"/>makes the change,'
          '<break time="150ms"/>runs the tests,<break time="300ms"/>and opens a pull request.</speak>',
    "fail": '<speak style="calm">On GitHub,<break time="150ms"/>one check fails.<break time="450ms"/>'
            '<prosody rate="94%">Sam doesn\'t need to step in.</prosody></speak>',
    "fix": '<speak style="calm"><emphasis>Fix failed checks</emphasis> starts another agent.'
           '<break time="300ms"/>It reads the log,<break time="150ms"/>fixes the cause,'
           '<break time="150ms"/>and pushes.</speak><speak style="bright">Green.</speak>',
    "review": '<speak style="calm">Sam leaves a review comment.<break time="350ms"/>When CodeRabbit '
              'finishes its review,<break time="150ms"/><emphasis>Address review comments</emphasis> '
              'picks up both.</speak>',
    "answer": '<speak style="calm">It fixes each one,<break time="150ms"/>answers in the thread,'
              '<break time="200ms"/>and pushes again.</speak>',
    "merge": '<speak style="warm">Sam decides what merges.<break time="400ms"/>One click.</speak>',
    "cost": '<speak style="calm">And the pull request says what the work took:<break time="200ms"/>'
            'three agents,<break time="150ms"/>their tokens,<break time="150ms"/>and their time.</speak>',
    "end": '<speak style="warm"><prosody rate="90%">Label an issue.<break time="250ms"/>Review.'
           '<break time="250ms"/>Merge.<break time="450ms"/>Agents do the rest.</prosody></speak>',
}

# The repository's seed: U1's package, with the low in Fahrenheit only. `main` is reset to it
# before each take. Units.swift is not in the house style, so CI's `format` job fails on the
# agent's first pull request whatever the agent writes (the script's line 5), and Fix failed
# checks formats it.
FORECAST = '''public struct Forecast {
    public var day: String
    public var highF: Double
    public var lowF: Double

    public init(day: String, highF: Double, lowF: Double) {
        self.day = day
        self.highF = highF
        self.lowF = lowF
    }

    /// The high in Celsius.
    public var highC: Double {
        Units.celsius(fahrenheit: highF)
    }
}
'''

UNITS = '''public enum Units {
  /// Degrees Fahrenheit in degrees Celsius.
  public static func celsius(fahrenheit: Double) -> Double { (fahrenheit-32)*5/9 }
}
'''

TESTS = '''import XCTest
@testable import Weather

final class ForecastTests: XCTestCase {
    func testHighInCelsius() {
        XCTAssertEqual(Forecast(day: "Monday", highF: 212, lowF: 50).highC, 100, accuracy: 0.01)
    }
}
'''

PACKAGE = '''// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Weather",
    targets: [
        .target(name: "Weather"),
        .testTarget(name: "WeatherTests", dependencies: ["Weather"]),
    ]
)
'''

SWIFT_FORMAT = '''{
  "version": 1,
  "indentation": { "spaces": 4 },
  "lineLength": 100
}
'''

CI = '''name: CI
on:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    container: swift:6.0
    steps:
      - uses: actions/checkout@v4
      - run: swift test
  format:
    runs-on: ubuntu-latest
    container: swift:6.0
    steps:
      - uses: actions/checkout@v4
      - run: swift format lint --strict --recursive Sources Tests
'''

FILES = {
    "Package.swift": PACKAGE,
    "Sources/Weather/Forecast.swift": FORECAST,
    "Sources/Weather/Units.swift": UNITS,
    "Tests/WeatherTests/ForecastTests.swift": TESTS,
    ".swift-format": SWIFT_FORMAT,
    ".github/workflows/ci.yml": CI,
    "README.md": "# Weather\n\nA day's forecast, in Fahrenheit and Celsius.\n",
    ".gitignore": ".build/\n",
}

# The open issues of Work ▸ Issues: #4 first, the one Sam hands over.
ISSUES = [
    ("Show the week's forecast", "A list of seven days, Monday first."),
    ("Say the wind speed", "In miles an hour, from the forecast's wind."),
    (ISSUE_TITLE, "Forecast has highC; add lowC, the low in Celsius, with a test."),
]

# The folder's Agents settings, in the repository: the cost comment, tokens only (a Claude
# subscription can say $0; the script's line 10 says "tokens and time").
FILES[".agents/folder.json"] = '{\n  "prCostComment": "tokens"\n}\n'

# The ready-made workflows the take turns on (docs/how-to/use-github.md, "Let agents work the
# dev loop"), by their titles on the Workflows page.
WORKFLOWS = ("Work an issue", "Fix failed checks", "Address review comments")

# Sam's git name on the commits the agents make; never the person's own (#5076).
SAM = {"GIT_AUTHOR_NAME": "Sam", "GIT_AUTHOR_EMAIL": "agentloops-dev-agent@users.noreply.github.com",
       "GIT_COMMITTER_NAME": "Sam", "GIT_COMMITTER_EMAIL": "agentloops-dev-agent@users.noreply.github.com"}


# --- Sam's GitHub ----------------------------------------------------------------------------
# The token is the demo account's (GITHUB_SAM_TOKEN, repo + workflow, #5076), read with
# agents-secret into this process only. It goes to gh and git in their environment, never on a
# command line, in a file of the checkout, or in a log.

def token():
    import subprocess
    value = subprocess.run(["agents-secret", "GITHUB_SAM_TOKEN"], capture_output=True, text=True).stdout.strip()
    if not value:
        raise RuntimeError("GITHUB_SAM_TOKEN cannot be read: in Settings ▸ You ▸ Secrets ▸ On This "
                           "Machine, turn its Ask before use off (#5122)")
    return value


def gh(*args, check=True, input=None):
    """gh as Sam, with the token in its environment only. Prints nothing of it."""
    import subprocess
    env = {**os.environ, "GH_TOKEN": token(), "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"}
    env.pop("GH_CONFIG_DIR", None)
    out = subprocess.run(["gh", *args], capture_output=True, text=True, env=env, input=input)
    if check and out.returncode != 0:
        raise RuntimeError(f"gh {args[0]} {args[1] if len(args) > 1 else ''}: {out.stderr.strip()[:300]}")
    return out.stdout.strip()


def gh_json(*args):
    import json
    text = gh(*args)
    return json.loads(text) if text else None


# A git credential helper that answers with the token from the environment, so the token is in
# no URL and no argument.
HELPER = '!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f'


def push_seed():
    """main, reset to the seed: one commit with a fixed author and date, so each take starts on
    the same commit. Force-pushed: the last take's merge is undone."""
    import subprocess
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory(prefix="vid-github-seed-") as tmp:
        for path, text in FILES.items():
            (Path(tmp) / path).parent.mkdir(parents=True, exist_ok=True)
            (Path(tmp) / path).write_text(text)
        date = "2026-11-10T09:00:00Z"
        env = {**os.environ, **SAM, "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date, "GH_TOKEN": token()}
        for cmd in (["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-qm", "Forecast, with the high in Celsius"],
                    ["-c", "credential.helper=", "-c", f"credential.helper={HELPER}", "push", "-q", "--force",
                     f"https://github.com/{REPO}.git", "main"]):
            out = subprocess.run(["git", "-C", tmp, *cmd], capture_output=True, text=True, env=env)
            if out.returncode != 0:
                raise RuntimeError(f"git {cmd[0]}: {out.stderr.strip()[:300]}")


def reset():
    """The repository as each take needs it, whatever the last take left: public, main at the
    seed, no open pull request or branch but main, the label `agent`, three open issues with
    ISSUE_TITLE newest (so it is first in Work ▸ Issues), and that issue with no label and no
    comment."""
    owner, name = REPO.split("/")
    if gh("api", f"repos/{REPO}", "--jq", ".full_name", check=False) != REPO:
        gh("repo", "create", REPO, "--public", "--description", "A day's forecast, in Fahrenheit and Celsius.")
    for pr in gh_json("pr", "list", "-R", REPO, "--state", "open", "--json", "number") or []:
        gh("pr", "close", str(pr["number"]), "-R", REPO)
    push_seed()
    for branch in gh_json("api", f"repos/{REPO}/branches", "--paginate") or []:
        if branch["name"] != "main":
            gh("api", "-X", "DELETE", f"repos/{REPO}/git/refs/heads/{branch['name']}")
    if "agent" not in (gh("label", "list", "-R", REPO, "--json", "name", "--jq", ".[].name") or "").split():
        gh("label", "create", "agent", "-R", REPO, "--color", "1D76DB", "--description", "An agent works this issue")
    issues = {i["title"]: i for i in gh_json("issue", "list", "-R", REPO, "--state", "all", "--limit", "50",
                                             "--json", "number,title,state") or []}
    for title, body in ISSUES:
        if title not in issues:
            gh("issue", "create", "-R", REPO, "--title", title, "--body", body)
            continue
        number = str(issues[title]["number"])
        if issues[title]["state"] != "OPEN":
            gh("issue", "reopen", number, "-R", REPO)
        gh("issue", "edit", number, "-R", REPO, "--remove-label", "agent", check=False)
        for comment in gh_json("api", f"repos/{REPO}/issues/{number}/comments", "--paginate") or []:
            gh("api", "-X", "DELETE", f"repos/{REPO}/issues/comments/{comment['id']}")


if __name__ == "__main__":
    # `python3 scripts/video/scenes/github.py reset`: the repository as a take needs it.
    import sys
    if sys.argv[1:] == ["reset"]:
        reset()
        print(f"{REPO}: reset")
