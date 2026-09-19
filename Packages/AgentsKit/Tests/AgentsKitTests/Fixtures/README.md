# Fixtures

## legacy-agent

An agent record written by the shipped version of the app before feature 003, copied verbatim out of
`~/Library/Application Support/Agents/agents/` on 2026-09-18. `transcript.jsonl` is the first 60
lines of a real transcript; `agent.json` is whole.

It exists for one test: that a newer build still opens a record an older build wrote. Do not
regenerate it with a newer build, and do not tidy it. Its value is that nothing in it was written by
the code under test.
