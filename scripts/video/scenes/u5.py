"""U5 Follow a live document (How-to ▸ Follow a live document): the page opening beside
the chat, the changes marked as the agent writes, and typing on it."""
import re

GROUP = "usage"
LAYOUT = "mac"
TITLE = "Follow a live document"
WINDOW = (1360, 820)

LINES = {
    "ask": "Ask an agent for a document, and ask to see it.",
    "opens": "The page opens beside the conversation, and fills in as the agent writes.",
    "marks": "Each change is marked for a moment, and the page follows the agent to it.",
    "type": "Click a passage, and type. Your words are saved to the file as you go, and the agent reads them on its next turn.",
}

PROMPT = "Write a short plan for adding a weekly forecast to plan.md, in three steps, and show it to me while you write it."


def last_passage(v):
    """The label of the page's last passage: the lowest wide button in the files pane."""
    best = (0, None)
    for line in v.walk.call("tree", depth=60)["text"].splitlines():
        line = line.strip()
        if not line.startswith("AXButton · ") or " @" not in line:
            continue
        label, box = line[len("AXButton · "):].rsplit(" @", 1)
        (x, y), (w, _) = (map(float, box.split(" ")[0].split(",")), map(float, box.split(" ")[1].split("x")))
        # Not a row of the file list, which is a file's name.
        if x > WINDOW[0] * 0.6 and w > 300 and y >= best[0] and not re.search(r"\.\w{1,4}$", label):
            best = (y, label.split(" #")[0])
    return best[1]


def setup(v):
    v.folder = v.project("weather-app", {"README.md": "# Weather\n\nA day's forecast, in Fahrenheit and Celsius.\n"})
    v.tidy()
    v.select("New Session")
    v.sleep(1.0)


def run(v):
    v.sleep(1.0)
    v.say("ask", wait=False)
    v.sleep(0.6)
    v.type("what do you want", PROMPT, 30)
    v.sleep(0.6)
    v.key("return")
    v.sleep(1.0)
    with v.fast(2.0):
        v.wait_until(lambda: "plan.md" in v.find("plan.md"), timeout=180, what="the page to open")
    v.say("opens")
    v.say("marks", wait=False)
    agent = v.newest_agent()
    with v.fast(4.0):
        v.wait_state(agent, states=("finished", "idle", "done"), timeout=300)
        # The page types the file out after the agent has written it.
        v.sleep(8.0)
    v.tidy()
    v.sleep(1.0)
    v.say("type", wait=False)
    v.sleep(1.5)
    # A passage on the page takes a press, and then the keyboard at its end.
    v.press("=" + last_passage(v))
    v.sleep(0.4)
    v.type_on(" Keep it to one screen.", 55)
    v.sleep(max(1.0, v.takes["type"]["duration"] - 2.5))
    v.sleep(1.5)
