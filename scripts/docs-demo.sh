#!/bin/sh
# A scratch copy of the app with demo projects in it, for the docs site's screenshots (044).
#
#   scripts/docs-demo.sh            build, launch on /tmp/run-044, add the demo projects
#   scripts/docs-demo.sh --no-build the same, without rebuilding
#   .claude/skills/run-app/scripts/stop.sh /tmp/run-044   when done
#
# Everything lives under /tmp/run-044: its own daemon, its own agents, two made-up projects.
# Nothing of the real app's (~/Library/Application Support/Agents) is read or shown, so a
# picture taken from this window has no real project, path or conversation in it.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
S="$root/.claude/skills/run-app/scripts"
ROOT=/tmp/run-044
demo="$ROOT/demo"

build=""
[ "${1:-}" = "--no-build" ] && build="--no-build"

cd "$root"
launched=$("$S/launch.sh" --slug 044 $build) || exit 1
eval "$launched"

# weather-app: a small Swift package with one failing test, for "Your first agent".
w="$demo/weather-app"
mkdir -p "$w/Sources/Weather" "$w/Tests/WeatherTests"
cat > "$w/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Weather",
    targets: [
        .target(name: "Weather"),
        .testTarget(name: "WeatherTests", dependencies: ["Weather"]),
    ]
)
SWIFT
cat > "$w/Sources/Weather/Forecast.swift" <<'SWIFT'
/// A day's forecast, as the weather service sends it: temperatures in Fahrenheit.
public struct Forecast {
    public var day: String
    public var highF: Double
    public var lowF: Double

    public init(day: String, highF: Double, lowF: Double) {
        self.day = day
        self.highF = highF
        self.lowF = lowF
    }

    /// The high in Celsius, for people who read it that way.
    public var highC: Double {
        (highF - 32) * 9 / 5
    }
}
SWIFT
cat > "$w/Tests/WeatherTests/ForecastTests.swift" <<'SWIFT'
import XCTest
@testable import Weather

final class ForecastTests: XCTestCase {
    func testHighInCelsius() {
        let monday = Forecast(day: "Monday", highF: 212, lowF: 50)
        XCTAssertEqual(monday.highC, 100, accuracy: 0.01)
    }
}
SWIFT
printf '# Weather\n\nA day'"'"'s forecast, in Fahrenheit and Celsius.\n\n    swift test\n' > "$w/README.md"
printf '.build/\n' > "$w/.gitignore"

# recipes-site: a plain web page, for guides that want a second project.
r="$demo/recipes-site"
mkdir -p "$r"
cat > "$r/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Recipes</title><link rel="stylesheet" href="style.css"></head>
<body>
  <h1>Recipes</h1>
  <ul>
    <li>Tomato soup</li>
    <li>Lemon cake</li>
  </ul>
</body>
</html>
HTML
printf 'body { font-family: system-ui; margin: 2rem; }\n' > "$r/style.css"

for p in "$w" "$r"; do
	if [ ! -d "$p/.git" ]; then
		git -C "$p" init -q -b main
		git -C "$p" add -A
		git -C "$p" -c user.name=Demo -c user.email=demo@example.com commit -qm "First version"
	fi
	"$S/rpc.py" "$ROOT" call projects/add "{\"folder\":\"file://$p\"}" >/dev/null
done

echo "ROOT=$ROOT"
echo "APP_PID=$APP_PID"
echo "DAEMON_PID=$DAEMON_PID"
