# 052 walk log

## Baseline (T001, T002), 2026-09-26

- Merged `main` into `agents/052-quota-fallback` at `0dc9fab`. `git merge-base --is-ancestor main HEAD` holds.
- On main, as the plan assumes: `runtimeError` (049), `usageLimit` (046), `quotaUsage` (046),
  `CredentialKind.openAIAPIKey` (047) and `.geminiAPIKey` (046) are all there.
- `swift test` in `Packages/AgentsKit`, run twice on `0dc9fab` in a detached worktree: **2337
  tests in 272 suites, all passed**, both runs (52 s and 35 s). Any later failure is this lane's
  only if it is new, and only after six runs on both commits.

## Slices 1 and 2 (T003–T023), 2026-09-26

- Slice 1 committed `9b7e375`: typed failures asked for, read, said, and never finished.
- Slice 2: recognition, allowance state, the stores and the words. A plan window arrives by
  `usage_update` and the turn's answer by the prompt's reply, and the answer can arrive
  first, so the window is carried on `TurnResult.rateLimit` as well (found by
  `AllowanceRecognitionTests` failing once, then fixed).
- Found in 049's tests: Antigravity's quota refusal is already captured ("Resource has been
  exhausted (e.g. check quota)."). It is treated as a rate limit that counts as spent after
  three in ten minutes, because Google uses the same words for both. Research R13 updated.
- Full suite on this branch, three runs: 2403 tests. Two passed clean; one failed only
  `theSettlingPauseIsNotStartedAgainByARestart`, which is on the `FlakyUnderLoad` list and
  passes alone. Before a fix, a slice-1 test left a 30 s rate-limit retry running after it
  ended, and the extra load failed `aQuietDirectLinkLosesAfterTheWindow` (also on the list)
  and `aPhoneThatComesStraightBackIsKnownAgain`. That test now retries nothing.
- T005 (the stand-in runtime executable) is deferred to the look gate, where it is first
  needed; nothing before it runs outside `swift test`.

## Look gate (T024–T032), 2026-09-26

Built against `scripts/seed-pool.py` on `/tmp/run-052-look` (the wireframes' moment, seeded as
files; the real Codex toolset linked in read-only so discovery finds it). Screenshots in
`walk/look/`:

1. `1-pool-page.png`: the sidebar's Pool row with its dot and count line; runtimes in order
   with payment capsules and state lines; Mark available on the two that are out; the prepaid
   key's "≈ $3.20 of $10.00 used"; Matching models; recent switches linking to their chats.
2. `2-chat-switch-note.png`: the tinted switch note (headline with return time, model and
   mode with where each came from, what was handed over, what was not carried, the two links)
   and the folded handoff.
3. `3-continue-with-menu.png`: the prompt bar's runtime control, with the per-chat tick, the
   pool's runtimes with their states, and Grok "not in the pool".
4. `4-continue-with-sheet.png`: the sheet's four columns and Won't carry over. Its right-hand
   column is a placeholder ("Claude's default") until the carry rules land in US1/US5, and
   Continue is disabled.

Not captured: Settings ▸ Pool and the Add credit sheet. Pressing a Settings tab through the
accessibility tree walks every menu and took over 40 s, so it was stopped. Both build and are
there to open by hand. Found and fixed on the way: times came out on a 12-hour clock with no
AM/PM (now the Mac's own setting); the switch note did not draw from seeded data, because a
record inside a transcript entry keeps dates as numbers, which the seed now does too; the shared
switch note used a macOS-only link style (the Remote now builds too).

The "⇄ Carried on from …" line on the agent row was added with US1 (2b6592d). It shows while
the chat is still on the runtime it moved to. Hiding it after the person's next prompt (as the
wireframe says) waits on the record keeping when that prompt was sent.

## US1: the automatic switch (T042), 2026-09-26

The run was on scratch root `/tmp/run-052-us1`, with `scripts/install-fake-runtimes.sh` stand-ins
as `grok` and `copilot` (`AGENTS_TEST_SEARCH_PATHS`). The pool was Grok (SuperGrok) then Copilot
(Copilot Pro). The steps were driven over `daemon.sock`, and nothing touched the real daemon.

1. Started a chat on Grok: "Plan the login redirect fix." Grok answered. The app's ask for a
   report ran on Grok too.
2. Wrote `spent` to `grok.behaviour` and prompted "Now make the change." Grok ended the turn
   with the typed failure (limit, no actions). The chat stopped as `allowanceSpent` with no "ran
   out" note, and then went on:
   `.poolSwitch` (Grok → Copilot, allowanceSpent), then `.handoff` (571 characters), then
   Copilot's reply: "copilot here. I was handed the conversation so far (571 characters).
   You said: Now make the change." That is one turn, with the handoff embedded and the prompt
   once. The person's words are on the record once.
3. `pool/state`: Grok out, `retryAfter` +1 h; Copilot available; one switch.
   `switches.jsonl` has one line.
4. The event log has `cost.allowance_out` (grok, until +1 h), then `agent.runtime_switched`
   (grok → copilot, allowanceSpent, with the agent and its title).
5. `pool/markAvailable` on Grok: state available, and `cost.allowance_back` (how: person).

Saved here: `us1/transcript.json`, `us1/pool-state.json` (taken before step 5),
`us1/switches.jsonl` and `us1/events.jsonl`.

There is no screenshot of the switch note from this run: the Mac was locked, and a locked screen
refuses window captures. The note is drawn by `SwitchNote` from the same record as the look gate's
`2-chat-switch-note.png`, which Alex approved.

A stand-in with no `loadSession` is started afresh on each later turn, with "… no longer has this
conversation" notes. That comes from the stand-in, not from the switch.


## US2: setting the pool and the credit ledger (T049), 2026-09-26

Driven over `daemon.sock` on the scratch root `/tmp/run-052-us2`. Alex was at the keyboard, so
nothing was clicked.

1. `pool/set` with Grok (SuperGrok), Copilot and a Codex key on $10 of prepaid credit: three
   entries, in that order.
2. The same pool reordered to Copilot, Grok, Codex: kept in that order.
3. Grok removed: Copilot, Codex.
4. A Codex key marked as an allowance was refused with -32602: "Codex on an API key is paid by
   use, so it cannot be an allowance." The pool was left as it was.
5. The app was stopped, keeping its root, and started again on the same root. `pool/state` then
   gave the same entries, byte for byte (`us2/pool-before-restart.json`,
   `us2/pool-state-after-restart.json`).

The ledger was not walked live: the stand-ins report no cost, and Codex runs only from the app's
own copy. `CreditLedgerTests` covers quickstart §6 end to end, with an injected clock:
- prepaid credit used up by what the turns cost, before any refusal;
- a used-up entry never reset by a clock;
- a grant past its date out at once, and never tried;
- Gemini's free tier back at midnight Pacific;
- spending not known;
- Mark available starting the count over;
- a raised amount bringing an entry back.

The walk found one bug, now fixed: Mark available kept the old spending, so the ledger called
new credit used up at once.

Not yet seen on screen: the Settings ▸ Pool Model menu, which is new, and the Add credit sheet's
key line and refusal. Both build, and are to be looked at when the screen is free.

## US3: the Pool page, live (T054), 2026-09-26

Run on the scratch root `/tmp/run-052-us3`, with the stand-ins, over `daemon.sock`. The window was
screenshotted from behind; nothing was clicked by me. Someone opened the Pool page between the
first two shots.

1. The pool was Grok then Copilot, both available: no dot.
2. With Grok spent, a chat started on Grok moved to Copilot. `pool/state` showed Grok out,
   Copilot with 1 chat, and 1 switch. `1-sidebar-out.png` shows:
   - the Pool row's dot, with "1 out · 1 chat on Copilot";
   - above a new session on Grok: "Grok is out, so its first turn would be refused. It is tried
     again after 10:26 AM." with **Use Copilot instead**.
3. `pool/markAvailable` on Grok: available, learned from the person, with `cost.allowance_back`
   on the event log. `2-sidebar-available.png` shows the dot gone live, and the Pool page with
   both runtimes "Available", Copilot "· 1 chat on it", and the switch row
   "9:26 AM Tidy the README. Grok → Copilot Grok's allowance ran out".

Found and fixed: the agent row's "⇄ Carried on from …" line was cut in half in the sessions list.
A list row keeps the height it first had, and the pool's state arrives after it. In the compact
row it is now a mark beside the title, like the workflow and started-by-agent marks, with the
sentence as its tooltip and accessibility label (`3-row-mark.png`). Cards keep the full line.

The notice had also given the one-hour retry time as a return time ("out until"), which nobody
had said. It now says "tried again after" for that case.

With the Settings rail from 055 merged in, Pool is a rail pane after Spending, and the Pool
page's two links open Settings on it. That is built, but not yet clicked.
