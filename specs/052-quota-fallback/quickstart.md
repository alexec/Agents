# Quickstart: proving 052 works

These checks prove the feature end to end. Every one of them runs on a **scratch root**, never
the real app, following the `run-app` skill. None of them spends a real allowance: the runtimes
that run out are stand-ins, and the only real checks are read-only.

## Prerequisites

- A worktree of this branch, built with the `run-app` skill's build step. Remember
  `-skipPackagePluginValidation`, and build both schemes one after the other.
- **A stand-in runtime.** This is the new test executable `fake-acp-runtime`, built from
  `FakeACPAgent.Script`. It is installed twice, as `grok` and as `copilot`, in a scratch folder
  named by `AGENTS_TEST_SEARCH_PATHS`. Each copy reads its script from
  `AGENTS_TEST_FAKE_SCRIPT_<NAME>`, which is a JSON file. The script can:
  - end a turn with a typed failure:
    `{"promptResultMeta": {"jetbrains": {"air": {"sessionFailure": {…}}}}}`;
  - send a `usage_update` carrying `_claude/rateLimit`;
  - reject a prompt with a JSON-RPC error of any code and text;
  - succeed after N failures.
- The package suite: `swift test --package-path Packages/AgentsKit`.

## 1. Recognition, without a daemon

Run `swift test --filter 'LimitRecognition|PoolPlan|SettingsCarry|Handoff'`.

Expect a test for every row of the tables in
[contracts/acp-session-failure.md](contracts/acp-session-failure.md). In particular:

- a `limit` failure with `[]` actions is `.spent`;
- a `limit` failure with `["retry"]` is `.rateLimited`;
- a `limit` failure with `["new_session"]` does not switch;
- Gemini's daily-quota 429 is `.spent`, and a plain 429 is a rate limit;
- an unknown error is `.none`;
- a turn with `end_turn` and an error failure is never `finished`.

## 2. A chat moves on by itself (US1)

1. On the scratch root, call `pool/set` with `isOn: true` and two entries: `grok`, then
   `copilot`, both `.allowance`.
2. Start an agent on `grok`, whose script ends every turn with a `limit`/`[]` failure. Send
   "hello".
3. Expect, without touching anything:
   - `agent/changed` shows `runtimeID: "copilot"`;
   - the transcript holds `.poolSwitch` (reason `allowanceSpent`), then `.handoff`, then Copilot's
     reply;
   - "hello" was received once by Copilot, after the handoff block, and never twice;
   - `pool/state` shows `grok` as out, with a `retryAfter` one hour ahead;
   - `events.jsonl` has `agent.runtime_switched` and `cost.allowance_out`.
4. Take a screenshot of the scratch window: the tinted note, as in wireframes §2.

## 3. What must not switch (US1-AS2, FR-006)

Repeat step 2 with each of these scripts. Each must end as it does on `main`, with no switch:

- a crash;
- a refused sign-in (the 043 `promptError`);
- a `limit`/`["new_session"]` failure;
- the person's own cost limit;
- an unrecognised error;
- a plain `end_turn`.

## 4. Rate limit, then persisting (FR-006a, R7)

1. Script `grok` to answer `limit`/`["retry"]` twice, then succeed. Expect two waits, the turn
   finishing on `grok`, no switch, and the entry showing *Rate limited* only while it waits.
2. Script it to rate-limit forever. Expect the third limit to mark it out, and the chat to move.

## 5. Never paying (FR-007, R3)

Script `grok` to send `usage_update` with
`_claude/rateLimit: {status: "allowed", isUsingOverage: true, resetsAt: <+2h>}`, then end the
turn normally. Expect the entry to be out, with the reason `overage` and until +2 h, the chat to
move at the end of that turn, and the note to say that paid extra usage had started.

## 6. Credit entries (US2-AS4…AS8)

- `pool/set` with a keyed entry marked `.allowance` must be rejected. So must any keyed entry
  that is not free or prepaid credit.
- Give a `.prepaid(amount: $0.05)` entry a script that reports `cost: 0.03` per turn. After the
  second turn, expect *Credit used up*, before the provider refuses.
- For a `.freeTier(.dailyAt(0, "America/Los_Angeles"))` entry refused with Gemini's daily-quota
  429, expect it to be out until the next midnight Pacific, and available again after that on its
  own.
- For `.freeCredit(expires: yesterday)`, expect the entry to be out at once, and never tried.
- Mark a used-up entry available. Expect it to be tried again, and never put back to
  `available` by a timer.

## 7. Everyone out (US4)

Both stand-ins refuse, `grok` with `_claude/rateLimit.resetsAt` in +2 minutes. Expect:

- the chat to show *Waiting for an allowance*, resuming on Grok at that time;
- `pool/state` to list the chat as waiting;
- the chat to resume on its own, two minutes later, with the prompt.

Repeat, but send a prompt while it waits. Expect the wait to be dropped (FR-017).

## 8. Continue with, and Matching models (US5, US6)

1. `pool/set` with a level that maps a model on `grok` to a model on `copilot`.
2. Preview `agents/continueWith`. Expect the `CarryPlan` rows to name that level as the source,
   the mode to be no looser than the current one, and `dropped` to list the extra arguments.
3. Apply with a changed model and **Remember** on. Expect the grid to gain that pair.
4. Run step 2 again, from another chat that has the same model. Expect the new runtime to start
   on the level's model.
5. Walk the Continue with sheet in the scratch window with the AX helper, pressing the runtime
   control, then a runtime, then Continue. Take screenshots against wireframes §3.

## 9. The Pool page (US3)

Drive the scratch window to the Pool row. Expect:

- the dot is shown while any entry is out;
- each state is in words;
- chat counts link to their chats;
- *Mark available* clears the dot without a relaunch (FR-024).

Take screenshots against wireframes §1. Build the Remote for the generic simulator only. The
phone's look is Alex's to check (see memory: no throwaway simulators).

## 10. Read-only checks against the real runtimes

These checks send no prompt, so they cost nothing. On a scratch root, start a Claude draft and a
Codex draft with the capability advertised. Check that:

- `initialize` succeeds;
- Claude's first `usage_update` carries `_claude/rateLimit`, with `status` and `resetsAt`;
- for Codex, it is recorded whether any rate-limit `_meta` arrives. This settles the open point
  in R2.

Write what was seen into research.md, under R2.

## Done when

- The suite is green, with six full runs compared against main, per the flaky-suite memory.
- Checks 2–9 pass on the scratch root, with their screenshots.
- `docs/` has the pages listed in the spec's Docs section.
