# Fixtures for the web remote (spec 071, research R7)

The rules the web remote ports from Swift to TypeScript, pinned by what Swift does. Each JSON
file is a list of cases, `{"name", "input", "expected"}`: the input is written by the Swift
encoders, and the expected output is the Swift rule run on it. `Web/test/*.test.mjs` runs the
TypeScript port on the same input and must get the same answer.

Written by `WebFixturesTests` (`Tests/AgentsKitTests/Unit/WebFixturesTests.swift`):

    AGENTS_WRITE_WEB_FIXTURES=1 swift test --package-path Packages/AgentsKit --filter WebFixtures

Without the variable the test runs every rule again and fails on any difference, so a change to
a Swift rule fails here until the fixtures are written again, and then fails the web tests until
the port follows. Do not edit these files by hand.

Each folder's README names the Swift it pins. `overrides/` holds Swift-encoded samples of the
types whose TypeScript is hand-written in `Packages/WebTypes/Overrides`.
