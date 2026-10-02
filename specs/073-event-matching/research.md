# Research: Finer event matching, step 1

The design questions are answered in [`specs/research/099-event-matching.md`](../research/099-event-matching.md).
This file records only what planning had to settle on top of that.

## R1. How a list is stored, so a downgrade still reads the record (FR-028, FR-029)

- **Decision**: `EventPattern` encodes as today, `{name, filters: {key: string}}`, with one
  addition when a filter is a list:
  - `filters[key]` holds the values joined by `|`;
  - a new key, `anyOf: {key: [values]}`, holds the list itself.

  The new decoder takes `anyOf` over `filters`. The previous version ignores `anyOf`, a key its
  synthesised decoder doesn't know. It reads `filters[key]` as the one value `done|nothing_to_do`,
  which matches nothing. Its status line still reads sensibly: `outcome done|nothing_to_do`.
- **Rationale**: FR-029 allows "a filter that never matches", and that is the safer of the two
  readings it allows: a wait that never fires, rather than one that fires too widely.
- **Alternatives**:
  - Encode `filters` as `{key: string | [string]}`. Rejected: the previous version's
    `[String: String]` decode throws, and the whole agent record is unreadable.
  - A separate `anyOf` key only, with no `filters` entry. Rejected: a downgrade would read the
    pattern as wider than written.

## R2. The workflow wire (FR-028, US5 scenario 4)

- **Decision**: event triggers already go over the wire as
  `.unrecognised(name, keys: [String: JSONValue])`. A list goes as a JSON array.
  - The new decoder reads arrays.
  - An older phone's `compactMapValues(scalar)` drops the array, and shows the trigger without
    that filter. That is the behaviour the spec accepts.
  - Firing is the host's, so nothing fires differently.
- **Rationale**: the wire keeps exactly its shape for singles.

## R3. Where old words become codes (FR-012, FR-013)

- **Decision**: each `EventDetail` with codes carries `oldWords: [String: String]`, mapping old
  words to codes. Fixed parts are matched by prefix or suffix (`wordsPrefix`).
- `EventPattern.parse` maps first, then checks values. A value that is neither a code nor old
  words is refused, naming the codes.
- `EventPattern`'s decoder (stored waits and run causes) maps too, but never refuses: a stored
  record is read, not judged. An unmappable old value stays as written and matches nothing, as it
  would today.
- The wire's decoder calls `parse`, so an unmappable value there makes the trigger
  `unrecognised`, and the page says so.
- **Mapping table**: in [contracts/catalogue.md](contracts/catalogue.md).
- The varying words map by their fixed part:
  - `this chain is already N deep` maps to `chain_too_deep`;
  - both over-limit messages map to `over_limit`;
  - `"X" is not something this version can watch for` maps to `trigger_not_supported`.
- `unreadable` and `setting_refused` carry the file's own error words. They can't be mapped, and
  are refused as FR-013 says.

## R4. `started_by` for an agent a `triggering` workflow adopted

- **Finding**: `startedByWorkflow` is also set when a workflow adopts an existing agent
  (`adoptAndPrompt`).
- **Decision**: precedence is `startedByAgent` → `agent`, then `startedByWorkflow` → `workflow`,
  else `person`. An adopted agent is then `workflow` from its first resume on. Since then it has
  been the workflow's: the agent list says so, and #102 treats it as the workflow's own.
- **Alternative**: a new field recording the original starter. Rejected for step 1: it would
  change the agent record, for a case the spec doesn't name.

## R5. `afterwards`

- **Decision**: `afterwards` is `park` when the agent is parked once the ending is through, and
  `stay` otherwise. That covers:
  - the agent's own `afterwards: park` on an ending it asked about;
  - the person's park while the turn ran (`whenTurnEnds`).
- **Found while building**: the rule can't be "this ending parked it". When an agent ends
  without a report, the app holds `agent.finished` back and asks it for an outcome. The person's
  park then lands on the first ending, and the finish is raised on the second. By then the agent
  is already parked.
- An agent the app resumes while parked (a wait's resume, for example) stays parked. It finishes
  `park` too: it is parked afterwards.

## R6. Which details are sets, and how they compare

- **Decision**: `EventDetail.isSet`. Only `labels` is a set in step 1.
- The event carries the label **keys** (`SessionLabelPolicy.key`), sorted and comma-joined.
- A filter value is keyed the same way at match time, so `Bug` matches `bug`, and
  `"needs review"` matches the label `needs review`.
- A `custom.` event's details are never sets: the catalogue isn't consulted for them.

## R7. Fixed values for `runtime`

- **Decision**: `RuntimeCatalog.builtIn` ids.
- `cost.allowance_out` and `cost.allowance_back` already carry `runtime`, so they share the
  check.

## R8. The web page's words

- **Decision**: port the phrase table for the keys FR-022 names into `Web/src/model/workflows.ts`:
  - `labels`, `runtime` and `outcome`;
  - `afterwards` and `started_by`;
  - the reason and `by` codes, via a small code-to-words table.

  Every other key reads `key a or b`. The page keeps its known difference: it names the event
  where the Mac says the catalogue meaning (parity.md, #98 row). But its filters now read as the
  Mac's do.
- Capsules and the cause phrase join a list with ` | ` and `|`.
- **Rationale**: no wire change. The page already ports a workflow's words by hand, held to
  fixtures. `generated.ts` changes only through the `EventPattern` override (the `anyOf` key) and
  the wait request's `where` type.
