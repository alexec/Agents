# Quickstart: proving MCP event triggers and the CI watcher

These are the runs that show the feature works. The setup details are in
[contracts/](contracts/) and [data-model.md](data-model.md).

## 0. Unit and integration tests (any lane, under the build lease)

```sh
scripts/build-cache.sh swift test --package-path Packages/AgentsKit \
  --filter 'MCPEventTrigger|JSONSchemaSubset|MCPEventStore|MCPEventWorkflow'
node --test Integrations/ci-watcher/
```

`MCPEventWorkflowTests` runs these against `EventsServerStandIn`, with a fake clock:

| Test | Shows |
|---|---|
| One event fires one run, and the details reach the prompt in the fence | US1 1, FR-008 |
| The same `eventId` twice gives one run | US1 3, FR-007 |
| A killed core with `delivering` ids, restarted: ids in the log are not raised again, ids not in the log are raised once | US2 1, R4 |
| The first poll's backlog is not raised | US2 2, FR-006 |
| `truncated` sets `missedSince` | US2 3 |
| Changed arguments give a new key and drop the old record | US2 4 |
| Off, archived, or another host's workflow: the server is never asked | US1 5, FR-011 |
| Unreachable, then back: `retrying` then `active`, with the backoff measured | US5 2, SC-004 |
| NotFound and Forbidden give `stopped`, and polling stops | US5 3 |
| Two workflows with one key: one poll, two runs | Edge case |
| Two stand-in servers offering one name: a trigger without `server:` gets two subscriptions and runs for each, `server: a` hears only `a`, `server: [a, b]` both, and arguments that fit only `a` give `b` a `badArguments` line while `a` still runs | US1 6 |
| `nextPollMs: 1` is clamped to 10 s | Edge case |

## 1. On a scratch root (run-app)

Never the real root. Seed synthetic records only, and never copy real agents.

1. Start the CI watcher against a scratch repo Alex owns, or the stand-in mode:
   `CI_WATCHER_FAKE=fixtures/ci.json node Integrations/ci-watcher/server.ts --port 8796`.
   The fake mode reads runs and PRs from a file, so the walk needs no GitHub.
2. Launch the app on a scratch root with a project whose `.agents/mcp.json` names
   `http://127.0.0.1:8796/mcp`. Approve the project's MCP file.
3. Add `.agents/workflows/fix-failed-checks.md` from
   [contracts/workflow-trigger.md](contracts/workflow-trigger.md) with `enabled: true`, and
   `AGENTS_TEST_RUNTIME=echo` so no real model runs.
4. **Expect**: the workflow page shows "Checked … · no events yet" within 30 s, on the Mac,
   and on the web page against the same root.
5. Append a failed run to `fixtures/ci.json`. **Expect**: within 40 s, one run, an agent whose
   prompt ends with the fenced data from `ci`, and one `checks.failed` event on the
   Events page.
6. Stop the daemon, append two more failures, and start it again. **Expect**: exactly two more
   runs. The log has two `raised` lines and no repeats.
7. Stop the CI watcher. **Expect**: "Can't reach ci" within one interval. Start it again.
   **Expect**: the line goes back to "Checked …" with no one doing anything.
8. Pin the `ui://ci/board` view from a `list_prs` call in a chat, and open the pin. **Expect**:
   the fake PRs with their check pills. Press **Rerun** on a failing one, and the fake records
   a rerun.

Screenshot steps 4, 5, 7 and 8 on the Mac and the web page. The Remote look is Alex's.

## 2. On this repo, with Alex's go-ahead

1. `Integrations/ci-watcher/run.sh start`, then `curl -s localhost:8795/health`.
2. Alex approves `.agents/mcp.json` in the app, and turns **Fix failed checks** on.
3. Open a draft PR with a failing test. **Expect**: within 2 minutes, an agent on that branch
   (SC-001), and the board shows the PR failing, then running after the agent reruns or pushes.
4. Over the following week, count runs against failures for SC-002 and SC-003, from the Events
   page (`checks.failed`) and the workflow's runs.

## Cleanup

- `Integrations/ci-watcher/run.sh stop` removes the LaunchAgent. Check with
  `launchctl list | grep ci-watcher`.
- Delete the scratch root, and remove the worktree's `build/` and `.build`.
