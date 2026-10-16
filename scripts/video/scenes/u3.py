"""U3 Answer a question (How-to ▸ Answer a question): the card, the choices, Other and
Submit, on the Mac and the phone at once."""
GROUP = "usage"
LAYOUT = "mac+phone"
TITLE = "Answer a question"

LINES = {
    "card": "When an agent asks you something, its card waits in the conversation, on your Mac and on your phone.",
    "pick": "Pick an answer. To say more, type it under Other.",
    "submit": "Click Submit. The agent carries on, and the card is gone from every screen.",
}

INDEX = '''<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Lumen</title></head>
<body>
  <h1>Lumen</h1>
</body>
</html>
'''

PROMPT = "Add a hero banner to index.html. Ask me the colour first: Ocean blue, Forest green or Sunset orange."


def setup(v):
    folder = v.project("landing-page", {"index.html": INDEX})
    v.start(folder, PROMPT)
    v.wait_until(v.pending_question, timeout=120, what="the question")
    v.tidy()
    v.select("Add a hero banner")
    v.open_phone()
    v.web("click", text="Add a hero banner")
    v.web("waitFor", expr='[...document.querySelectorAll("button")].some((b) => b.textContent.trim().startsWith("Forest green"))')
    v.sleep(1.0)


def run(v):
    v.sleep(1.0)
    v.say("card")
    v.say("pick", wait=False)
    v.sleep(1.0)
    v.press("Forest green,")
    v.sleep(1.2)
    v.type("after:other", "with a soft fade at the bottom", 45)
    v.sleep(max(0.5, v.takes["pick"]["duration"] - 2.0))
    v.say("submit", wait=False)
    v.sleep(1.0)
    v.press("=Submit")
    v.wait_until(lambda: not v.pending_question(), timeout=20, what="the card to clear")
    v.sleep(v.takes["submit"]["duration"] + 1.5)
