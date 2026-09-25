# 042 walk notes

## Baseline (T002)

`swift test` in `Packages/AgentsKit` at `6246cb0` (this branch with `main` `0ea158d` merged in,
before any 042 code), run once in a detached copy at `/tmp/042-base`, on 2026-09-25:

- 1729 tests in 187 suites, all passed, exit 0.

A later failure is this lane's only if it is new against this, and only after six runs on
both commits (the suite is flaky under load).

## Look gate, Phase 3 (T026)

Scratch root `/tmp/run-042`, Debug build of `49478db`, the wireframe's night raised by hand
with `events/raise` (a debug-only method, refused on the real root):

- `mac-events-page.png`: the page, day headings, filters, consequences, sidebar "Last 07:40".
- `mac-event-detail.png`: a row opened: details, position, meaning, Copy as trigger.
- `mac-events-live.png`: a `custom.ping` raised with the page open arrives at the top
  without a refresh; the sidebar line follows.

Not yet on screen: Waiting now (needs a real wait, Phase 4), the chat capsule and hint line
(Phase 4), the phone and iPad list (Alex's, on a device).

Look gate (T027): approved by Alex, 2026-09-25 ("The events page looks right"). Phone look not yet done.
