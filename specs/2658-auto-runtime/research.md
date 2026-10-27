# Research: Auto Runtime

## R1. Where Auto is resolved

- **Decision**: in the daemon, at `agents/start` (`turns.go startFor`).
- **Rationale**: the daemon already has every input: runtime availability (`runtimes/list`), the
  out state (`allowances.go`), the advertised options (`options.go runtimeOffers`) and the
  sandbox and organisation rules. A server folder resolves on the server, with its own runtimes
  (spec edge case). Three clients get one answer (SC-006).
- **Alternatives**: resolve in each client — three copies of the rules, and the web page has no
  allowances cache of its own. Rejected.

## R2. Where the person's settings live

- **Decision**: `<SettingsDir>/auto.json`, written by `auto/set`; the Mac sends the same file to
  each machine, as it does for `sandbox/set`.
- **Rationale**: the spec's FR-017 asks for `~/.agents`, but the daemon's per-person settings
  (`sandbox.json`, `client-permissions.json`, `modes.json`) all live in `<Root>/settings`. One
  place for them is simpler, and the fan-out already exists. The spec is changed to say so.
- **Alternatives**: `~/.agents/auto.json` — a second settings place, read by the daemon only for
  this. Rejected.

## R3. How a level becomes a native setting

- **Decision**: a shipped table per runtime and field gives the native config option id and
  value (`mode=plan`, `model=claude-opus-5-5`, `effort=high`), or a launch setting (sandbox,
  client permission). Each cell is checked against `runtimeOffers(runtimeID)` before use.
- **Rationale**: model and mode ids are the runtime's; they cannot be derived from words. The
  check against the advertised options keeps to principle II and finds dropped values without a
  network call.
- **Alternatives**: pick by option category and position (first mode = most restrictive) —
  fragile; the order of modes is not a promise. Rejected.

## R4. Nearest safer

- **Decision**: each runtime's modes get an access rank in the table (0 = read only … 3 = full
  access). The auto-map for a level takes the native mode with the highest rank that is not over
  the level's rank. No such mode gives **Not possible**.
- **Rationale**: it makes SC-005 a test over the table.

## R5. Fixed sandboxes and **No sandbox**

- **Decision**: a runtime with a fixed **Default sandbox** (Grok, Cursor, Copilot) maps **No
  sandbox** to its default, marked **nearest safer**, not **Not possible**.
- **Rationale**: the spec's draft table left this to the plan. Less access than asked is the
  safe side, and skipping three runtimes for it would leave Auto with few choices.
  Decided: allow it with a note, because it follows the nearest-safer rule. Alex can overrule.

## R6. Libraries

No parser, protocol or format is new. No library is needed.

## R7. Gemini's "Auto" model

The Gemini model option named Auto stays a native value. It shows **Custom** on the model pill.
No conflict with the runtime Auto, which is a runtime id, not an option value.
