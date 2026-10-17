"""U4 Read an agent's changes (How-to ▸ Read an agent's changes): the Changes pane, the
list of files, and the changed words coloured."""
GROUP = "usage"
LAYOUT = "mac"
TITLE = "Read an agent's changes"
WINDOW = (1360, 820)

LINES = {
    "open": "To see what an agent changed, open the sidebar on the right.",
    "changes": "Click Changes. Every file it touched is listed, with the lines added and removed.",
    "file": "Click a file to read the change. Within a line, the words that changed are coloured, so a small edit stands out.",
    "whole": "Switch to Whole file to read it in context.",
}

FORECAST = '''/// A day's forecast, as the weather service sends it.
public struct Forecast {
    public var day: String
    public var highF: Double
    public var lowF: Double

    /// The high in Celsius.
    public var highC: Double {
        (highF - 32) * 9 / 5
    }

    /// The low in Celsius.
    public var lowC: Double {
        (lowF - 32) * 9 / 5
    }
}
'''

PROMPT = ("In Forecast.swift, the Celsius conversions multiply by 9/5; they should multiply by 5/9. "
          "Fix both, and add a one-line summary property that says the day, high and low in Celsius.")


def setup(v):
    folder = v.project("weather-app", {"Forecast.swift": FORECAST, "README.md": "# Weather\n"})
    agent = v.start(folder, PROMPT)
    v.wait_state(agent, states=("finished", "idle", "done"), timeout=300)
    v.tidy()
    v.unfold("weather-app")
    v.sleep(0.5)
    v.select_agent(agent)
    v.sleep(1.5)


def run(v):
    v.sleep(1.0)
    v.say("open", wait=False)
    v.sleep(1.5)
    v.press("Sidebar On The Trailing Side")
    v.sleep(max(0.5, v.takes["open"]["duration"] - 1.0))
    v.say("changes", wait=False)
    v.sleep(1.2)
    v.press("=Changes | Changes")
    v.sleep(v.takes["changes"]["duration"])
    v.say("file", wait=False)
    v.sleep(1.0)
    v.press("Forecast.swift, changed")
    v.sleep(v.takes["file"]["duration"] + 0.5)
    v.say("whole", wait=False)
    v.sleep(1.0)
    v.press("Whole file")
    v.sleep(v.takes["whole"]["duration"] + 2.0)
