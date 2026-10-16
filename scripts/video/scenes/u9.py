"""U9 Use Agents in a browser (How-to ▸ Use Agents in a browser): Open in Browser pairs the
browser in the same step, and the page has the same sidebar."""
GROUP = "usage"
LAYOUT = "mac+browser"
TITLE = "Use Agents in a browser"
BROWSER = (1200, 760)
WINDOW = (1180, 740)

LINES = {
    "intro": "Agents runs in a browser on your Mac, too.",
    "menu": "In the window, choose View, then Open in Browser.",
    "paired": "The page opens, and pairs that browser in the same step. There's nothing to copy or paste.",
    "same": "It's the same sidebar and the same agents. Answer them from either one.",
}


def setup(v):
    folder = v.project("weather-app", {"README.md": "# Weather\n"})
    agent = v.start(folder, "Add a line to README.md saying the app shows the weekly forecast.")
    v.wait_state(agent, states=("finished", "idle", "done"), timeout=300)
    v.project("landing-page", {"index.html": "<h1>Lumen</h1>\n"})
    v.tidy()
    v.unfold("weather-app")
    v.open_browser(pair=False)
    v.sleep(1.0)


def run(v):
    v.sleep(1.0)
    v.say("intro")
    v.say("menu", wait=False)
    v.sleep(1.2)
    v.menu("View", "Open in Browser")
    url = v.wait_until(v.opened_url, timeout=20, what="the page's address")
    v.sleep(max(0.3, v.takes["menu"]["duration"] - 1.2))
    v.say("paired", wait=False)
    v.web("eval", expr=f"location.href = {url!r}")
    v.web("waitFor", expr='document.querySelector(".row .title")', timeout=30000)
    v.sleep(v.takes["paired"]["duration"])
    v.say("same", wait=False)
    v.sleep(1.0)
    v.web("click", text="weather-app")
    v.sleep(v.takes["same"]["duration"] + 1.5)
