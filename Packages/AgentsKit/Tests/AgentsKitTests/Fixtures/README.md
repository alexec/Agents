# Fixtures

## legacy-agent

An agent record written by the shipped version of the app before feature 003, copied verbatim out of
`~/Library/Application Support/Agents/agents/` on 2026-09-18. `transcript.jsonl` is the first 60
lines of a real transcript; `agent.json` is whole.

It exists for one test: that a newer build still opens a record an older build wrote. Do not
regenerate it with a newer build, and do not tidy it. Its value is that nothing in it was written by
the code under test.

## GitHub

Responses to `GitHubQuery.text` (038), written by hand in the shape a real response had on
2026-09-25. Nothing here came from calling GitHub in a test. `pulls-mixed.json` is the wireframes'
moment: #412 failing and changes requested (with comments from a collaborator, a member, a
contributor, a stranger, a bot and the viewer), #405 approved, #398 failing through a status
context, #390 a conflicting draft still running, and #377 timed out.
