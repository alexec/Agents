# US5 walk: workflows, listed and run now

**Date:** 2026-10-01

**Commit:** the T068 commit on `agents/write-spec-first-version`.

**How it was run:**
- On the scratch root `/tmp/run-webus5`, with a scratch window.
- Headless Chrome drove the page at 1440 × 900, using `Web/test/walk/us5.mjs`.
- The work project held three workflows in `.agents/workflows/`, each approved on the host's own socket (standing in for the window):
  - `greeting.md`: on a schedule (Sundays at 3am), in a new agent, writing "hello" into `greeting.txt`;
  - `after-build.md`: on the event `custom.build_green`, in a new agent, in plan mode;
  - `old.md`: archived.
- The run's one permission (writing the file) was answered in the page. Claude ran the turn for real.

There were three runs, each on a freshly seeded root. The first found that the run's permission card never showed in the page. The second showed Run Now pressed against the column's edge. The notes and screenshots here are from the third, after both fixes.

## Scenarios

| # | Scenario | Result |
|---|----------|--------|
| 1 | A project's workflows are listed under its sessions, with their triggers | "Write a greeting: Sun at 3am, in a new agent" and "After the build: When custom.build_green, in a new agent, in plan mode". Both were marked "Waiting for its trigger", and each had Run Now. |
| 2 | Archived workflows are folded away | The fold read "Archived workflows 1", closed. Opened, it held "An old one", marked Archived, with no Run Now. |
| 3 | Run Now starts a run on the host | A new agent appeared on the host 4.7 s after the click (1.3 s and 6.3 s in the earlier runs). It was started by `greeting` and labelled `workflow`. |
| 4 | The run's session is found under the project | The page showed it under Working as "Write a greeting". The scratch window opened on it too (`us5-window-1-ran.png`). |
| 5 | The run is steered from the page | Its permission was already waiting when the chat was opened by its link, and the card was there on arrival. Allowed in the page, the run finished: "Created greeting.txt in the project folder containing the word "hello"." Claude then renamed the session "Greeting file". `greeting.txt` holds `hello`. Afterwards the workflow's row went back to "Waiting for its trigger". |

There were no page errors.

## Found and fixed during the walk

**A question already waiting when a chat was opened was never shown.**
- **Cause:** `Cards.tsx` had two effects: one that held the session's live cards, and a second that cleared them whenever the session changed. On a chat's first render the clearing effect ran second, so it wiped the cards the first had just taken in. Only a request that arrived after the chat opened got through.
- **Fix:** one effect now does both. It notes which session its cards belong to, and starts from nothing only when that changes.
- This mattered beyond workflows: any permission or question pending when a chat was opened from the list was missing until something else arrived.

**Run Now ran past the column's edge.**
- **Cause:** a workflow row is a `div`, not a `button` like the session rows, so `.row`'s `width: 100%` added its padding on top. Its button also shared the class `run` with the chat's tool-call runs.
- **Fix:** the row is sized border-box, and the button is `run-now`.

## What isn't the window's yet

- **Event triggers** are said by name and filters ("When custom.build_green"). The window says them from its event catalogue ("When an agent here publishes…"), which the page doesn't have.
- **Editing:** a workflow can't be approved, edited, archived or made from the page. FR-028 asks only for listing and Run Now; a workflow waiting for approval says "Waiting for your OK on the Mac".
- **The window's workflow detail** (its runs and their outcomes) isn't in the page; a run is found through its session.

## Screenshots (`walks/us5/`)

- `us5-1-listed.png`: the workflows under the sessions, with the archived fold closed.
- `us5-2-ran.png`: the run's session under Working, just after Run Now.
- `us5-3-done.png`: the finished run in the page.
- `us5-window-1-ran.png`, `us5-window-2-done.png`: the scratch window on the same run.
