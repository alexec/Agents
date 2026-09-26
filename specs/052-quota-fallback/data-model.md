# Data Model: Carry On When a Runtime Runs Out

The types are in `AgentsKitCore` unless a line says otherwise. Every one of them is `Codable`,
`Hashable` and `Sendable`, and each decodes a key it does not know by ignoring it. That is the
rule the store already follows (FR-021 of 001).

## PoolEntry

One runtime with one way of paying for it (FR-001, FR-001a).

| field | type | notes |
|---|---|---|
| `id` | `UUID` | stable; switch records and ledgers are keyed by it |
| `runtimeID` | `String` | a `RuntimeCatalog` id |
| `payment` | `Payment` | see below |
| `credentialRef` | `String?` | which lent credential (043/047), for a keyed entry; `nil` means the runtime's own sign-in |
| `fallbackModel` | `JSONValue?` | the "Model" menu in Settings ▸ Pool; `nil` = "as the chat had" |

`Payment` is an enum:

- `.allowance(label: String?)` — label as shown, e.g. "Max plan", "ChatGPT plan"; taken from the
  runtime's account report where it gives one (Codex `ChatGPT <planType>`).
- `.freeCredit(amount: Cost?, expires: Date?)`
- `.prepaid(amount: Cost?, expires: Date?)`

There is deliberately no `.unlimited` case: open-ended billing cannot be represented, so it
cannot be stored (FR-001a, SC-002).

Validation on `pool/set`:

- `runtimeID` must be known.
- A keyed entry (`credentialRef != nil`) must be `.freeCredit` or `.prepaid`.
- An `.allowance` entry must have `credentialRef == nil`, or name a subscription token. That
  covers `CredentialKind.oauthToken` for Claude. An API-key credential can never be an allowance.
- Amounts are positive.

## Level (a Matching models row)

| field | type | notes |
|---|---|---|
| `id` | `UUID` | |
| `name` | `String` | the person's own name, 1–40 characters |
| `cells` | `[String: Cell]` | keyed by `runtimeID`, not by entry, because two entries for one runtime share a column |

`Cell` is `{ model: JSONValue, effort: JSONValue?, effortOptionID: String? }`.

The grid is validated as a whole (FR-032). Within one runtime, a model value may appear in at most
one level. `pool/set` rejects a grid that breaks this, and says which cell broke it.

## PoolSettings (`pool.json`)

| field | type | default |
|---|---|---|
| `isOn` | `Bool` | `false` |
| `entries` | `[PoolEntry]` | `[]`, in order of trying |
| `levels` | `[Level]` | `[]` |

`isEffective` is `isOn && entries.count >= 2` (FR-003).

## AllowanceState (`allowances.json`, one per entry per host)

| field | type | notes |
|---|---|---|
| `entryID` | `UUID` | |
| `status` | `Status` | see below |
| `since` | `Date` | when the status last changed |
| `learnedFrom` | `Source` | `.typedFailure`, `.words`, `.overageReport`, `.ledger`, `.expiry`, `.person` |
| `lastRateLimit` | `RateLimitInfo?` | the latest `_claude/rateLimit` or Codex snapshot, kept for the return time (R2) |
| `spent` | `Spent` | `.known(Cost)` or `.unknown`; only for credit entries |
| `rateLimitStreak` | `[Date]` | times of consecutive rate limits, trimmed to the last 10 min (R7) |

`Status` is an enum:

- `.available`
- `.rateLimited(until: Date)` — not "out"; nothing moves (FR-006a)
- `.out(until: Date?, retryAfter: Date?, why: OutReason)`
  - `until` is set when the runtime said, and is `nil` for credit
  - `retryAfter` is the one-hour rule when `until` is `nil` and the entry is an allowance
- `.unusable(why: Unusable)` — not signed in, not installed, or the credential is missing on this
  host. Derived on read from `RuntimeAccount` and discovery, never stored.

`OutReason` is one of `.allowanceSpent`, `.overage`, `.creditUsedUp`, `.creditExpired` or
`.rateLimitPersisted`.

Transitions:

```text
available ──typed quota / words──────────▶ out(until?, retryAfter?)
available ──rate limited────────────────▶ rateLimited(until) ──retry succeeds──▶ available
rateLimited ──3rd in 10 min─────────────▶ out(retryAfter: +1h, .rateLimitPersisted)
available ──overage reported────────────▶ out(until: resetsAt, .overage)
available ──ledger ≥ amount─────────────▶ out(nil, .creditUsedUp)
available ──expires passed──────────────▶ out(nil, .creditExpired)
out(until) ──until passes───────────────▶ available
out(retryAfter) ──next switch after it──▶ tried again; a success makes it available
out(any) ──Mark available / amount raised─▶ available   (learnedFrom: .person)
```

A credit entry that is `out` never goes back to `available` on a timer (FR-001c).

## Agent (additions to the existing record)

| field | type | notes |
|---|---|---|
| `poolEntryID` | `UUID?` | the entry the chat is on now; `nil` when it started outside the pool |
| `switchingOff` | `Bool` | the per-chat "Carry on when … runs out" (FR-003), default `false` |
| `allowanceWait` | `AllowanceWait?` | `{ resumeAt: Date, entryID: UUID, prompt: QueuedPrompt }` (R8) |
| `triedForPrompt` | `[UUID]` | entries already tried for the pending prompt; cleared by any real reply (spec Edge Cases, flapping) |

`runtimeID`, `runtimeSessionID`, `startOptions`, `advertisedOptions` and `availableCommands`
are already on the record. A switch **replaces** them. It never adds a second set.

## SwitchRecord (`switches.jsonl`)

| field | type |
|---|---|
| `id` | `UUID` |
| `at` | `Date` |
| `agentID` | `UUID` |
| `from` | `{ entryID?, runtimeID, model?, mode? }` |
| `to` | `{ entryID, runtimeID, model?, mode? }` |
| `reason` | `.allowanceSpent`, `.overage`, `.creditUsedUp`, `.rateLimitPersisted`, `.everyoneOutResumed` or `.byHand` |
| `carried` | `[CarriedSetting]` — each `{ optionID, from?, to?, source: .level(name) / .sameValue / .poolEntry / .remembered / .runtimeDefault / .strictestMode / .person }` |
| `dropped` | `[Dropped]` — `.extraArguments`, `.alwaysAllow(count)`, `.queuedSlashCommand(name)` |
| `shortened` | `Int?` — the number of turns left out of the handoff |
| `billing` | `Payment` of the entry switched onto |

Lines over 30 days old are dropped at start (FR-025).

## TranscriptEntry (additions)

- `.poolSwitch(SwitchRecord)` — drawn as the tinted note (wireframes §2).
- `.handoff(markdown: String, characters: Int)` — drawn folded under the note, never as a bubble
  (R4).
- `.settingsChanged(SwitchRecord)` — written when "Change what it carried on with…" applies
  (FR-029).

## EndedReason (additions)

- `allowanceSpent` — "Its allowance ran out." Used only when the chat did **not** move, because
  switching was off, there was no pool, or everyone was out.
- `rateLimited` — "Rate limited, and still limited after retrying."

## Derived views (not stored)

- **`PoolStatus`** — what the Pool page and the phone draw: the entries with their `Status`, the
  number of chats on each, the waiting chats, the latest 1 day of switches, and `anyOut`, which
  lights the sidebar dot.
- **`CarryPlan`** — what `SettingsCarry.plan` returns: rows of
  `{ optionID, name, now, next, choices, source }` plus `dropped`. The Continue with sheet draws
  it directly.
