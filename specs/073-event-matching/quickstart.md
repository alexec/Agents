# Quickstart: proving finer event matching

## Unit

```sh
swift test --package-path Packages/AgentsKit --filter 'EventPattern|EventFilter|EventCatalogue|WorkflowTrigger|EventWait|AppService|WorkflowFile'
cd Web && npm test
scripts/web.sh check
```

What they cover:
- SC-001: each of the nine triggers matches its event and not its near miss.
- SC-003: every existing pattern test still passes unchanged.
- SC-004: the problem sentences.
- FR-028 and FR-029: the encoding round-trip and the downgrade.

## On a scratch root, over the socket

Uses the run-app skill: a scratch control plane, host and window on `/tmp/run-073`.

1. Seed a git project with `.agents/workflows/bugfix.md`, holding T1. Approve the workflow.

   ```yaml
   ---
   on:
     - agent.finished:
         labels: bug
         afterwards: park
   ---
   Write up the fix.
   ```

2. Raise the events with `events/raise`. That is `raiseByHand`, which only a debug build accepts,
   and only on a scratch root. The daemon's own details are covered by the integration tests,
   which finish real fake-runtime agents. Raise:
   - `agent.finished` with `labels: bug,p1`, `afterwards: park` (the match);
   - `agent.finished` with `labels: bug`, `afterwards: stay` (the near miss);
   - `agent.finished` with `labels: perf`, `afterwards: park` (the near miss).
3. Read `workflows/list`. Only the first event has a `fired` consequence, and the workflow's
   `lastFiredBy` is `agent.finished`.
4. Screenshot the workflow page by window id. The Triggers section reads
   *When an agent in this project ended a turn having done its work (labelled bug, and parked)*,
   with the capsules `afterwards: park` and `labels: bug`.
