"""A2 Answer from anywhere (Home, Why Agents): four agents working, one asks, the card on
the phone, one tap, the Mac carries on. The second test video was the draft."""
GROUP = "marketing"
LAYOUT = "mac+phone"
TITLE = "Answer from anywhere"

LINES = {
    "l1": "Monday morning. Four agents are already hard at work on your Mac.",
    "l2": "One's fixing the checkout bug. One's writing tests. One's tidying up the docs.",
    "l3": "And this one... has a question.",
    "l4": "Not at your desk? No problem. The question is already on your phone.",
    "l5": "One tap, and it's answered.",
    "l6": "And back on your Mac, it's straight back to work.",
    "l7": "Agents. Your coding agents, wherever you are.",
}

CART = '''def total(prices, discount_percent=0):
    """The cart's total after a percentage discount."""
    subtotal = sum(prices)
    if discount_percent > 1:
        subtotal -= subtotal * discount_percent / 100
    return round(subtotal, 2)
'''

UTIL = '''def slugify(title):
    return "-".join(title.lower().split())


def initials(name):
    return "".join(part[0].upper() for part in name.split())
'''

README = '''# docs-site
how to install: pip install docs-site. usage run docs-site serve. if it breaks try again
'''

INDEX = '''<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Lumen</title></head>
<body>
  <h1>Lumen</h1>
  <p>Photos, sorted for you.</p>
</body>
</html>
'''

AGENTS = [
    ("checkout-api", "Fix the checkout bug: a 1% discount in cart.py is ignored. Add a test in test_cart.py and run it."),
    ("ios-app", "Write unit tests for util.py in test_util.py and run them."),
    ("docs-site", "Tidy up README.md into clear docs with Install, Usage and Troubleshooting sections."),
    ("landing-page", "Add a hero banner to index.html. Ask me the colour first: Ocean blue, Forest green or Sunset orange."),
]


def setup(v):
    v.folders = {
        "checkout-api": v.project("checkout-api", {"cart.py": CART}),
        "ios-app": v.project("ios-app", {"util.py": UTIL}),
        "docs-site": v.project("docs-site", {"README.md": README}),
        "landing-page": v.project("landing-page", {"index.html": INDEX}),
    }
    v.tidy()
    v.open_phone()


def run(v):
    v.sleep(0.8)
    v.say("l1", wait=False)
    for name, prompt in AGENTS:
        v.start(v.folders[name], prompt)
        v.sleep(1.2)
    for name, _ in AGENTS:
        v.unfold(name)
    v.tidy()
    v.sleep(1.5)
    v.say("l2")
    with v.fast(1.5):
        ask = v.wait_until(v.pending_question, timeout=120, what="the question")
    v.select("Add a hero banner")
    v.tidy()
    v.sleep(0.5)
    v.say("l3")
    v.say("l4", wait=False)
    v.sleep(1.0)
    v.web("click", text="Add a hero banner")
    v.web("waitFor", expr='[...document.querySelectorAll("button")].some((b) => b.textContent.trim().startsWith("Ocean blue"))')
    v.sleep(v.takes["l4"]["duration"])
    v.say("l5", wait=False)
    v.sleep(0.9)
    v.web("click", text="Ocean blue")
    v.sleep(0.7)
    v.web("press", name="Submit")
    v.sleep(v.takes["l5"]["duration"])
    v.wait_until(lambda: not v.pending_question(), timeout=20, what="the card to clear")
    v.say("l6")
    with v.fast(3.0):
        v.sleep(20)
    v.tidy()
    v.say("l7")
    v.sleep(1.5)
