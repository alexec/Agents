# Fixtures

## legacy-agent

An agent record written by the shipped version of the app before feature 003, copied verbatim out of
`~/Library/Application Support/Agents/agents/` on 2026-09-18. `transcript.jsonl` is the first 60
lines of a real transcript; `agent.json` is whole.

It exists for one test: that a newer build still opens a record an older build wrote. Do not
regenerate it with a newer build, and do not tidy it. Its value is that nothing in it was written by
the code under test.

## claude-edits.jsonl, claude-edits.expected.json

The tool-call entries of one real Claude agent's transcript (2026-09-24), every call that carried a
diff and nothing else: 352 entries, 99 edits. Paths are rewritten under `/fixture/`, each file's
text is replaced by numbered stand-in lines of the same count, and `raw`/`rawOutput` are dropped;
everything else — the order, the repeated diffs, the Write whose first copy has no old text, the
calls with several diffs, the call that failed — is as the runtime sent it.

`claude-edits.expected.json` is the list of edits 035's fold must produce (research R1: the last
diff of each call, completed calls only), worked out by a throwaway script rather than by the code
under test. It is SC-002's check.

## GitHub

Responses to `GitHubQuery.text` (038), written by hand in the shape a real response had on
2026-09-25. Nothing here came from calling GitHub in a test. `pulls-mixed.json` is the wireframes'
moment: #412 failing and changes requested (with comments from a collaborator, a member, a
contributor, a stranger, a bot and the viewer), #405 approved, #398 failing through a status
context, #390 a conflicting draft still running, and #377 timed out.
