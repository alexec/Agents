# Contract: daemon API for the pool

These are JSON-RPC methods on `daemon.sock`, and through the bridge to the phone. They follow the
existing names (`runtimes/…`, `agents/…`, `cost/setLimits`). Types are those in
[../data-model.md](../data-model.md).

Roles (security review, Phase 3): reading is open to the **owner** and to **paired devices**.
Every write is open to the **owner** only, except `pool/markAvailable` and `agents/continueWith`,
which paired devices may also call. They are the phone's two actions (wireframes §5).

## pool/state → `PoolStatus`

Params `{}`. The whole Pool page in one call: settings, each entry's status, chats per entry,
waiting chats, and switches from the last day. When `{ "days": 30 }` is passed, it returns the
last 30 days of switches (FR-021, FR-025).

## pool/set → `PoolSettings`

Params: a `PoolSettings`. The whole thing is replaced, as `cost/setLimits` does. It rejects with
`-32602` and a sentence in these cases:

- a keyed entry that is not free or prepaid credit (FR-001a);
- an API-key credential marked as an allowance;
- a model in two levels for one runtime (FR-032);
- an unknown runtime.

On success it broadcasts `pool/changed`, and the app pushes the new settings to connected
servers (R6).

## pool/markAvailable → `PoolStatus`

Params `{ entryID }`. Sets the entry to `available`, with `learnedFrom: .person`, and broadcasts
`pool/changed` (FR-023). It is idempotent.

## pool/models → `{ runtimeID: [ConfigOption] }`

Params `{ runtimeIDs: [String] }`. The model and effort options each runtime offers, taken from
the option cache, with a draft handshake for any runtime missing from it (R10). This is what
fills the grid's menus.

## agents/continueWith

Two steps, on the same pattern as `retention/set`'s `confirmed`:

- **Preview:** params `{ agentID, entryID }` → `CarryPlan`. Nothing changes.
- **Apply:** params `{ agentID, entryID, choices: { optionID: JSONValue }, remember: { levelID? , newLevelName? }? , confirmed: true }` → `Agent`.

Apply rejects in these cases:

- `-32010` "Stop the turn first" while a turn is running (US5-AS2);
- a mode looser than the chat's current mode (FR-027);
- a choice value the runtime does not offer.

On success it:

1. writes `.poolSwitch` with the reason `.byHand`;
2. replaces the runtime, the session and the options on the record;
3. appends a `SwitchRecord`;
4. publishes `agent.runtime_switched`;
5. saves any **Remember** choice into the grid.

Nothing is sent to the new runtime until the person's next prompt. The handoff goes with that
prompt (FR-018, R4).

### After an automatic switch

After an automatic switch, the same two steps are called with `{ agentID, adjust: true }`, with
no entry. The preview returns a `CarryPlan` whose runtime is fixed. Apply writes
`.settingsChanged` and sets the options for the next turn. It never makes a new session and never
re-sends anything (FR-029).

## agents/setSwitching

Params `{ agentID, isOn }`. Sets the per-chat switch (FR-003). It broadcasts `agent/changed` as
any record change does.

## Notifications

- **`pool/changed`**: `PoolStatus`. Sent on any settings change, status change or switch. The
  sidebar dot and the page redraw from it (FR-024). It is debounced to at most once a second.
- **`agent/changed`**: the existing notification, now carrying the new fields.

## Events (042 catalogue)

- `agent.runtime_switched`: `{ agent, from, to, reason, entry }`
- `cost.allowance_out`: `{ entry, runtime, until?, reason }`
- `cost.allowance_back`: `{ entry, runtime, how }`, where `how` is `time`, `person`, `success`
  or `amount_raised`
