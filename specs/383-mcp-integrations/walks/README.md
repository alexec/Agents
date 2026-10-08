# T044: quickstart §1, walked 2026-10-07 and 2026-10-08

On a run-app scratch root (`/tmp/run-w383`), with the CI watcher in fake mode on port 8793
(8792 is the live web port), a copy of `fixtures/ci.json`, `AGENTS_TEST_RUNTIME=echo` and the
workflow on the demo runtime. Synthetic records only. The web page was walked in headless
Chrome against the same control plane; the Remote's look is Alex's.

| Step | Result | Shots |
|---|---|---|
| 4 | Active, "Checked … · no events yet", about 50 s after the project's MCP file was approved: approvals are picked up by the once-a-minute look. Before the fix in #421, the Mac drew no line at all. | `mac-4-before-fix-no-line.png` |
| 5 | One failed run, one run, its prompt ending with the fenced data from `ci`; one `checks.failed` event. | `mac-5-workflow.png`, `mac-5-agent-prompt.png`, `web-step5.png` |
| 6 | Host stopped, two failures appended, host started: two `raised` lines, no repeats. A second restart raised nothing. Of the two, the second was refused (`runInFlight`): #422. | daemon log |
| 7 | CI watcher stopped: "Can't reach ci since … · trying again in …" in the warning colour, backoff 10, 20, 40, 80 s; started again, back to "Checked …" by itself. A pinned board meanwhile says its call did not answer. | `mac-7-down.png`, `mac-7-back.png`, `mac-7-board-down.png`, `web-step7-down.png`, `web-step7-back.png` |
| 8 | `list_prs` from a real Claude turn, Show, pinned: the board draws the fake PRs with their pills. Rerun on #402 records a rerun of run 9001, and its pill turns Running. | `mac-8-board.png`, `mac-8-rerun.png`, `web-step8-1.png`, `web-step8-2.png` |

## Found

- The window and the Remote drew no trigger lines: `WorkflowSummary`'s lenient decoder never read
  `mcpTriggers`. Fixed in #421.
- A trigger without `server:` whose only server waited for approval said no server offers the
  event. Fixed in #421.
- Two events in one poll ran the workflow once: the second was refused while the first ran.
  Alex chose to queue it: #422.
- The web page says the trigger as "checks.failed (repo alexec/Agents)"; the Mac says "When a
  server here reports checks.failed (repo alexec/Agents)": #424.
