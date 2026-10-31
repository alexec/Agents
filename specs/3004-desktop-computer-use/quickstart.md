# Quickstart: prove desktop control works

How to see each user story working, slice by slice. Use only scratch data: the repo is
public. Hold the `build` lease only while a build, a test or a scratch app runs; hold the
`screen` lease yourself (by hand, from **Resources**) while poking at the real pointer
during a walk, so a real agent cannot take it mid-test. Close every scratch app with the
run-app skill's "When you are done" steps.

## Before you start

- A worktree of the slice's branch, and `scripts/build-cache.sh` for every build and test.
- A Mac with Accessibility available to grant (System Settings ▸ Privacy & Security ▸
  Accessibility): the scratch Agents Host build will ask for it on first use, same as
  `run-app`'s own driver does today.
- Contracts: [contracts/desktop-control-api.md](contracts/desktop-control-api.md). Types:
  [data-model.md](data-model.md).

## First: confirm the open risk in research R1

Before building the real feature, build a throwaway `Contents/Helpers/agents-drive` that
only calls `AXIsProcessTrusted()` and prints the answer, ship it beside a scratch Agents
Host build, trigger the Accessibility prompt, grant it, and read System Settings ▸ Privacy
& Security ▸ Accessibility: does the new row say **Agents Host**, or does it name the
helper by its own path? Write the answer at the top of this file once known, and name
whichever one it is in FR-005's refusal card and in
`docs/how-to/let-an-agent-drive-desktop-apps.md`.

## Slice 1: the lease, the tool, and Off by default (US1, US2)

1. On a scratch root, confirm **Settings** shows desktop control **Off**, with a line
   saying what it allows (US2 Acceptance Scenario 1).
2. Call `drive_screen` from a scratch agent while Off. Expected: refused, with a card
   naming the rule and where to turn it on (FR-004).
3. Turn it on. Call `drive_screen` again before granting Accessibility. Expected: refused,
   with a card naming where to grant it (FR-005 Acceptance Scenario 2).
4. Grant Accessibility (the first-check from "Before you start" above). Call `drive_screen`
   again. Expected: it succeeds, with no further system prompt on this Mac (FR-005
   Acceptance Scenario 3); **Resources** shows `screen` held by the agent.
5. From a second scratch agent, call `drive_screen` while the first holds it. Expected: it
   waits in line, exactly as `lease_resource("screen")` would (FR-002 Acceptance Scenario 4).
6. Give the first agent a task reachable only through a non-browser app with no API (for
   example, Preview: open a file, crop, export). Confirm each step shows in the chat as an
   ordinary part of the turn, then press **Stop**. Expected: the action stops, `screen` is
   released at once, and **Resources** shows it free (FR-009, SC-004).

```sh
scripts/build-cache.sh Go/scripts/go.sh test ./internal/agentsd/...
```

## Slice 2: pause on touch, Resume and Take Over (US3)

1. Start a `drive_screen` run against a scratch app. While it is mid-action, move the real
   mouse. Expected: the action stops within the second (SC-002; try this 20 times over a
   session to confirm the bound holds every time), and a card with **Resume** and **Take
   Over** appears on every client showing the session.
2. Choose **Resume**. Expected: the agent continues the action from where it paused (US3
   Acceptance Scenario 3).
3. Run it again, pause it, and choose **Take Over**. Expected: `screen` is released at
   once (SC-004), and the chat says the person took over (US3 Acceptance Scenario 2).
4. Confirm the helper's own synthetic events never trip the pause (research R2): a long
   `type` action with many keystrokes does not pause itself.

## Slice 3: the live tile on Mac, Remote and web (US4)

With the run-app skill, Mac and headless Chrome; the walk simulator for the Remote. One
screenshot per state and per client, for the PR (`pr-shots.sh`):

| State | Clients | Expected |
|---|---|---|
| A session holds `screen`, opened fresh | Mac, web, Remote | live tile: latest screenshot + narration, refreshed within 2 s of the next action and at least every 5 s idle (FR-011) |
| The Mac's screen is locked, `screen` still held | Mac (another device's view of it), web, Remote | "Mac is locked" placeholder + narration only, no screenshot (FR-012, FR-013); confirm no image bytes are sent at all, not merely hidden client-side |
| Mid-run, the Remote backgrounded, then the run pauses (slice 2) | Remote | the same notice as any other turn needing attention |
| The same session from the web page | web | the same tile, the same Resume/Take Over/Stop controls |
| An older client (temporarily drop `host.desktop-control/1` with a test flag) | any | the session shows as an ordinary running turn, no tile, no error (Edge Cases, "An older client") |

Also confirm SC-005: after the run, grep the project folder, `<root>`, and the turn's saved
transcript for anything that looks like image data from this feature. Nothing should
match.

## Slice 4: the runtime's own `computer_use` is off (FR-010)

Start a scratch Codex agent. Read its effective `CODEX_CONFIG` (or its launch
environment) and confirm `features.computer_use` is `false`. Confirm
`docs/reference/runtimes.md`'s row says "Superseded by the app's own desktop-control
tool."

```sh
scripts/go-changed.sh
```
under the `build` lease, before any push that changes `Go/`.

Also: `swift test` (filtered by `scripts/select-test-suites.sh`) for the new Swift types
and cards, and `WireSchemaTests`, under the `build` lease.
