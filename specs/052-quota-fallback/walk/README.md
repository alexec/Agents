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

## US4: everyone out, wait, then carry on (T055–T057), 2026-09-26

The run was on the scratch root `/tmp/run-052-us4`, with the stand-ins, driven over `daemon.sock`.
The stand-in now takes `spent <epoch>`, which sends a plan window saying when it is back, as
Claude's does. The pool was Grok (out until 10:00:04) then Copilot (out, with no time given).

1. A chat started on Grok with "Tidy the README." Grok refused it. The chat moved to Copilot,
   which refused it too. The chat then stopped as `allowanceSpent`, and waited:
   "Every runtime in the pool is out. This chat waits, and carries on with Grok at 10:00 AM."
   `pool/state` listed it under `waiting` (`us4/pool-state-waiting.json`). In
   `1-waiting.png` (mostly covered by the scratch root's first-run install sheet), the row
   shows a grey stop icon, not the attention colour, with the hourglass mark, and the Pool row
   shows "2 out".
2. Grok was set to answer again. At 10:00:09, the first heartbeat after 10:00:04, the chat
   carried on by itself. The transcript has `.poolSwitch` copilot → grok (everyoneOutResumed)
   and a handoff, then Grok's reply to the refused words, sent once: "You said: Tidy the README."
   The wait was cleared (`us4/transcript.json`, `2-carried-on.png`).

Found and fixed:
- **A switch carried the old runtime's plan window.** Claude's rate-limit data is kept per
  chat, so when Codex failed after a move, Codex was marked out until Claude's reset time. A
  switch now clears it.
- **Retry times read as return times.** "ran out, until 10:58 AM" gave the app's own one-hour
  retry as if the provider had said it. It now reads "It is tried again after …", and a wait
  is scheduled only on a time the provider gave (`knownReturn`).

`AllowanceWaitTests` (7) cover:
- the wait and its note;
- carrying on once, at the time, on the entry that is back;
- stop, park and archive dropping the wait;
- the person's next prompt replacing it;
- Stop waiting;
- no known return, in which case it stops and schedules nothing;
- a restart that keeps the wait and still carries on.

## US5: Continue with, by hand (T058–T061), 2026-09-26

The run was on the scratch root `/tmp/run-052-us5`, and was driven through the window with the AX
helper while nobody was at the keyboard (idle over 250 s, unlocked). The stand-ins now offer a
model (`<name>-fast`, `<name>-smart`) and a mode (default, acceptEdits, bypassPermissions), so
there are settings to carry. Copilot had run once in the folder, so what it offers there was
remembered.

1. The prompt bar's runtime control (`1-menu.png`) shows the per-chat tick, "Carry on when Grok
   runs out", then CONTINUE WITH Copilot.
2. Copilot opens the sheet (`2-sheet.png`), matching wireframes §3. The title carries a runtime
   picker and the pool state ("Available"). The rows are Model (grok-smart → copilot-smart,
   "Copilot's default") and Mode (default → default, "the same as now"). Under them is Won't
   carry over. Remember is shown but switched off until the grid (US6).
3. Picking copilot-fast marks the row "chosen by you" (`3-chosen.png`). **Continue on Copilot**
   moved the chat: it is on Copilot with `model: copilot-fast`, `mode: default`. The note reads
   "Continued with Copilot. Model: copilot-fast, chosen by you · Mode: default, the same as
   before. Copilot is given the conversation so far with your next message." The prompt bar
   shows Copilot and copilot-fast (`4-moved.png`). Nothing was sent.
4. The note's **Change what it carried on with…** opens the sheet in adjust mode
   (`5-adjust.png`): "From its next turn. Nothing is started again and nothing is sent again."
   Its button stays off until something is changed.
5. The next prompt, "Now make the change.", reached Copilot with the handoff: "copilot here. I
   was handed the conversation so far (548 characters). You said: Now make the change."
   (`us5/transcript.json`).

Found and fixed: what a runtime offers in a folder was remembered only by the new-session form.
So a runtime that had run there as a chat left nothing for the preview. Starting a chat, and
moving one, now remember it too.

Not seen on screen: the mode menu with its looser values left out, and "Stop the turn first"
with its Stop button. `ContinueWithTests` covers both refusals.

## US6: Matching models (T062–T066), 2026-09-26

The run was on the scratch root `/tmp/run-052-us6`, with the stand-ins, which offer a model each
(`<name>-fast`, `<name>-smart`).

1. A chat on Copilot, then one on Grok, so each had said what it offers in the folder.
2. `pool/models {grok, copilot}` answered `grok: [grok-fast, grok-smart]` and
   `copilot: [copilot-fast, copilot-smart]`. Only the model is listed, not the mode, and
   nothing was started, since both were remembered.
3. `agents/continueWith` moved the Grok chat to Copilot on copilot-fast with
   `remember: {newLevelName: "Everyday"}`. The pool then had one level, **Everyday**, with
   `grok: grok-smart`, `copilot: copilot-fast` (`us6/pool-state.json`).

There is no screenshot: the Mac locked (idle about 15 minutes) before the Pool page could be
captured. The editable grid builds, and is still to be seen on screen:
- cell menus from `pool/models`;
- Add a level;
- Rename…, Move up/down and Remove on a level's name;
- gone models struck through;
- a model moving out of its other level.

The rules behind it are covered by `MatchingModelsTests` and `PoolModelsTests`:
- a gone cell is treated as empty;
- placing a model moves it;
- Remember goes in the level that already holds the chat's model, else a new one;
- a runtime never seen is started once, sent no prompt, and not started again within ten
  minutes;
- Remember through Continue with keeps FR-032.

Found on the way: the run-app launch opened a window that never started its daemon, after
earlier scratch windows had been killed. Opening with `-ApplePersistenceIgnoreState YES` (the
memory note's workaround) worked.

## Servers: a plan out on one side is out on the other (T070), 2026-09-26

The run was on the devbox (`agents@127.0.0.1:2222`, Linux aarch64), with this branch's Linux
`agentsd` built by `scripts/build-linux-agentsd.sh`. It ran from its own path and root
(`~/agentsd-052 --root ~/r052 --serve`), so the box's own install was left alone. It was
reached over a real `ssh -L` socket forward. The stand-ins were on both sides: on the box in
`~/.local/bin` (the server found them), and on the Mac through `AGENTS_TEST_SEARCH_PATHS` on a
headless Mac daemon. Both pools were Grok (SuperGrok) then Copilot.

The screen was locked, and a locked session exposes no window to accessibility (the tree comes
back as the application repeated), so the window could not add the server. The window's part
was played by hand with the same calls it makes: `pool/set` to the server as on connect, and
`PoolStatus.shared` from one daemon to `pool/applyAllowances` on the other. The window's own
relay code (`AppModel.receivedFromServer`, `sendSharedAllowances`) is not exercised here. It
builds, and the daemon side is what `ServerAllowanceTests` covers.

1. A server chat on Grok: "Tidy the README." It answered.
2. A Mac chat on Grok was refused (`spent`). The Mac's Grok was out, and the chat moved to
   Copilot. The Mac's `shared` was `[grok:sign-in out]` (`servers/mac-pool-state.json`).
3. `pool/applyAllowances` on the server with it answered `true`, and again `false`: the same
   word twice changes nothing. The server's rows were Grok out, Copilot available.
4. The server chat was prompted: "Now make the change." It moved to Copilot **before** its turn,
   with no Grok refusal in its transcript. Copilot answered, "I was handed the conversation so
   far (516 characters). You said: Now make the change." (`servers/server-transcript.json`).
5. The other way: Copilot was set `spent` on the box and the server chat prompted again. The
   server's `shared` then held both plans out. Applied on the Mac, it answered `true`: the Mac's
   rows were both out, with `cost.allowance_out` "learned from another host"
   (`servers/server-pool-state.json`).

Cleaned up afterwards: the forward, both daemons, `~/r052`, `~/agentsd-052` and the box's
stand-ins.

Found and fixed:
- **`cost.allowance_out` gave the app's retry time as `until`.** It now gives `until` only for a
  time the provider gave, and `retry_after` otherwise.
- **A race that could lose a prompt.** Four places wrote an agent's record back after an await,
  over whatever had changed meanwhile: starting a wait, the chat's switch, adjust, and the
  switch itself. A prompt queued, or a Stop waiting, in that gap was undone. Each now writes
  with no await between reading and writing. `AllowanceWaitTests` failed about one run in
  three before the fix, and passed 18 runs out of 19 after it.
