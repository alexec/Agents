"""U1 Your first agent (Tutorials ▸ First agent): add a project, New Session, say what you
want, answer the agent, watch its steps and its reply."""
GROUP = "usage"
LAYOUT = "mac"
TITLE = "Your first agent"

LINES = {
    "intro": "This is Agents. Here's how to start your first agent.",
    "project": "A project is a folder you work in. Add one, and it appears in the sidebar.",
    "new": "Click New Session. The agent works in the project folder, with Claude as its runtime.",
    "prompt": "Say what you want done. Here, fix the Celsius conversion, and run the tests.",
    "send": "Send it, and the agent starts at once.",
    "ask": "Before it changes a file or runs a command, it asks. Click Yes.",
    "steps": "Its steps appear as it works: what it read, the edit, and the tests it ran.",
    "reply": "When it's done, its reply says what it changed. That's your first agent.",
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

PROMPT = "The Celsius conversion in Forecast.swift is wrong. Fix it, and run the tests."


def setup(v):
    v.tidy()


def run(v):
    v.sleep(1.0)
    v.say("intro")
    v.mark("add")
    folder = v.project("weather-app", {
        "Package.swift": PACKAGE,
        "Sources/Weather/Forecast.swift": FORECAST,
        "Tests/WeatherTests/ForecastTests.swift": TESTS,
        "README.md": "# Weather\n\nA day's forecast, in Fahrenheit and Celsius.\n",
        ".gitignore": ".build/\n",
    })
    v.say("project")
    v.select("New Session")
    v.say("new")
    v.say("prompt", wait=False)
    v.sleep(1.2)
    v.type("what do you want", PROMPT, 40)
    v.sleep(0.8)
    v.answer_permissions = False
    v.key("return")
    v.say("send")
    with v.fast(2.0):
        ask = v.wait_until(lambda: (v.rpc("permissions/pending") or [None])[0], timeout=120, what="a permission card")
    v.tidy()
    v.sleep(0.8)
    v.say("ask")
    v.press("=Yes")
    v.answer_permissions = True
    v.sleep(1.0)
    v.say("steps")
    agent = ask["agentID"]
    with v.fast(3.0):
        v.wait_state(agent, states=("finished", "idle", "done"), timeout=300)
    v.tidy()
    v.sleep(1.0)
    v.say("reply")
    v.sleep(1.5)
