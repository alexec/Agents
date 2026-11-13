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

# The demo repository: Sam's own account (#5076). AGENTS_VIDEO_GITHUB_REPO overrides it.
REPO = os.environ.get("AGENTS_VIDEO_GITHUB_REPO", "loops-sam/weather")
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
