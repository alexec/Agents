"""U1 Your first agent (Tutorials ▸ First agent): the Get started card, add a folder, New
Session, say what you want, answer the agent, watch its steps, its reply and its Changes.
The script is section 2.1 of specs/4832-videos/spec.md (#4835)."""
GROUP = "usage"
LAYOUT = "mac"
TITLE = "Your first agent"
WINDOW = (1360, 820)
# The card is the story here: make.py and v.tidy() leave it showing.
GET_STARTED = True
DOCS = "tutorials/first-agent/"  # the docs page, on docs.agentloops.dev (upload.py)

# Directed lines (voice.py, #4964): pauses, pace and tone, as Alex heard them on 2026-11-12.
LINES = {
    "intro": '<speak style="warm">This is Agents.<break time="500ms"/>'
             'Here\'s how to start your <emphasis>first</emphasis> agent.</speak>',
    "folder": '<speak style="calm">A folder is a directory you work in.<break time="450ms"/>'
              'Add one,<break time="200ms"/>and it appears in the sidebar.</speak>',
    "new": '<speak style="calm">Click <emphasis>New Session</emphasis>.<break time="450ms"/>'
           'The agent works in this folder,<break time="150ms"/>with Claude as its runtime.</speak>',
    "prompt": '<speak style="calm">Say what you want done.<break time="500ms"/>'
              '<prosody rate="92%">Here: fix the Celsius conversion,<break time="200ms"/>and run the tests.</prosody></speak>',
    "send": '<speak style="bright">Send it,<break time="250ms"/>and the agent starts at once.</speak>',
    "ask": '<speak style="calm">Before it changes a file or runs a command,<break time="200ms"/>'
           'it asks.<break time="500ms"/>Click <emphasis>Yes</emphasis>.</speak>',
    "steps": '<speak style="calm">Its steps appear as it works:<break time="350ms"/>what it read,'
             '<break time="200ms"/>the edit,<break time="200ms"/>and the tests it ran.</speak>',
    "reply": '<speak style="calm">When it\'s done,<break time="200ms"/>its reply says what it changed,'
             '<break time="350ms"/>and Changes shows the edit.</speak>',
    "end": '<speak style="warm"><prosody rate="90%">That\'s your first agent.</prosody></speak>',
}

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
        (highF - 32) * 9 / 5
    }
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

FILES = {
    "Package.swift": PACKAGE,
    "Sources/Weather/Forecast.swift": FORECAST,
    "Tests/WeatherTests/ForecastTests.swift": TESTS,
    "README.md": "# Weather\n\nA day's forecast, in Fahrenheit and Celsius.\n",
    ".gitignore": ".build/\n",
}

PROMPT = "Fix the Celsius conversion and run the tests."


def setup(v):
    # Nothing added yet: the window is empty but for the Get started card.
    v.wait_until(lambda: v.find("Get started"), timeout=30, what="the Get started card")


def rest_of(v, key, spent):
    """Waits out what is left of line `key` after `spent` seconds of it."""
    v.sleep(max(0.3, v.takes[key]["duration"] + 0.4 - spent))


def run(v):
    v.sleep(1.0)
    v.say("intro")

    # 2. Add a folder: the card's step, then the folder in the sidebar and the step ticked.
    v.say("folder", wait=False)
    v.sleep(1.5)
    v.add_folder("weather", FILES)
    v.wait_until(lambda: v.find("weather"), timeout=20, what="the folder in the sidebar")
    rest_of(v, "folder", 1.5)

    # 3. New Session on the folder: the start form, with Claude.
    v.say("new", wait=False)
    v.sleep(1.0)
    v.select("New Session")
    rest_of(v, "new", 1.0)

    # 4. The prompt, typed as a person would.
    v.say("prompt", wait=False)
    v.sleep(1.2)
    v.type("what do you want", PROMPT, 45)
    rest_of(v, "prompt", 1.2 + len(PROMPT) * 0.05)

    # 5. Send: the session is Working in the sidebar.
    v.answer_permissions = False
    v.key("return")
    v.say("send")

    # 6. The permission card, and Yes.
    with v.fast(2.0):
        ask = v.wait_until(lambda: (v.rpc("permissions/pending") or [None])[0], timeout=180, what="a permission card")
        v.wait_until(lambda: v.find("=Yes"), timeout=90, what="the card in the window")
    v.sleep(0.8)
    v.say("ask", wait=False)
    v.sleep(max(1.5, v.takes["ask"]["duration"] - 1.2))
    v.press("=Yes")
    v.answer_permissions = True
    v.sleep(1.2)

    # 7. Its steps fill in, cut short.
    v.say("steps", wait=False)
    agent = ask["agentID"]
    with v.fast(4.0):
        v.wait_state(agent, states=("finished", "idle", "done"), timeout=300)
    v.sleep(0.6)
    # The line is said over the sped-up span and after it: wait out what is left.
    v.sleep(max(0.5, v.takes["steps"]["duration"] - 4.0))

    # 8. The reply, then the Changes pane with the fix in colour.
    v.say("reply", wait=False)
    v.sleep(2.5)
    v.press("Sidebar On The Trailing Side")
    v.sleep(0.6)
    v.press("=Changes | Changes")
    v.sleep(1.0)
    v.press("Forecast.swift, changed", wait=3)
    rest_of(v, "reply", 4.1)

    # 9. Done, and the card ticks Start your first agent.
    v.say("end")
    v.sleep(1.5)
