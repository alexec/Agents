"""U8 Start in a worktree (How-to ▸ Start in a worktree): two agents on one repository,
each in a worktree of its own."""
GROUP = "usage"
LAYOUT = "mac"
TITLE = "Start in a worktree"

LINES = {
    "two": "Two agents can work in one repository without getting in each other's way.",
    "choose": "Before you send, open Worktree, and choose New worktree.",
    "own": "The agent gets its own copy of the project, on a new branch.",
    "second": "Start a second one the same way. Each works in its own worktree, on its own branch.",
}

PROMPTS = [
    "Add a dark mode toggle to settings.py.",
    "Add a weekly summary to report.py.",
]


def setup(v):
    v.folder = v.project("weather-app", {
        "settings.py": "THEME = 'light'\n",
        "report.py": "def report(days):\n    return [d.summary() for d in days]\n",
    })
    v.tidy()
    v.select("New Session")
    v.sleep(1.0)


def start_one(v, prompt):
    v.press("Project folder | Worktree")
    v.sleep(1.2)
    v.press("New worktree, A new branch")
    v.sleep(0.8)
    v.type("what do you want", prompt, 40)
    v.sleep(0.5)
    v.key("return")


def run(v):
    v.sleep(1.0)
    v.say("two")
    v.say("choose", wait=False)
    start_one(v, PROMPTS[0])
    v.sleep(1.0)
    v.say("own")
    v.unfold("weather-app")
    v.select("New Session")
    v.sleep(1.0)
    v.say("second", wait=False)
    start_one(v, PROMPTS[1])
    v.sleep(2.0)
    v.unfold("weather-app")
    v.sleep(max(1.0, v.takes["second"]["duration"] - 3.0))
    v.press("=Worktrees | Every project's worktrees")
    v.sleep(3.5)
