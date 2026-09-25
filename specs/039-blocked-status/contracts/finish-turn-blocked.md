# Contract: `finish_turn` with `blocked`

## 1. Tool schema (AppService, `finishTurnTool`)

The same tool, with three changes. `report_outcome` (the older name) gets the same enum value
and the same two properties.

```jsonc
"outcome": { "enum": ["done","nothing_to_do","needs_answer","partly_done","stuck","blocked"] },
"waiting_on": {
  "type": "array", "items": { "type": "string" },
  "description": "Only with blocked. The agents in this project you are waiting on, by id (as start_agent or list_my_agents gave it) or by exact title. You will be resumed once every one has finished."
},
"check_again_in_minutes": {
  "type": "integer", "minimum": 1, "maximum": 1440,
  "description": "Only with blocked. When to be resumed anyway, to check on something the app can't see (a CI run, a review)."
}
```

Added to the description's list of outcomes:

```
  blocked         You are waiting on something other than the person: agents you
                  started, another agent's change, a CI run. Name the agents in
                  waiting_on and you will be resumed, with how each one ended, once
                  they have all finished. For something the app can't see, say what
                  it is and give check_again_in_minutes. Not for a question to the
                  person (that is needs_answer) or for a dead end (that is stuck).
```

The message for `blocked` is what it is waiting on, in the agent's own words.

Local checks in `AppService` (before relaying): `waiting_on` or `check_again_in_minutes` sent
with any other outcome is refused: "waiting_on and check_again_in_minutes only go with
blocked." A non-integer, or a value outside 1…1440, is refused with the range.

## 2. Daemon refusals (`checkedReport`, in this order)

Every refusal writes nothing, and each comes back as a sentence the agent reads:

| Condition | Message (shape) |
|-----------|-----------------|
| An entry matches no agent in the project | `Nothing was recorded: no agent in this project is called "X". The agents here are: <id: "title">, …` |
| An entry matches more than one title | `Nothing was recorded: "X" could be any of <id: "title">, …. Use the id.` |
| A UUID of an agent in another project | `Nothing was recorded: <id> is in another project. You can only wait on agents in this one.` |
| Itself | `Nothing was recorded: you can't wait on yourself.` |
| Already ended (research R3) | `Nothing was recorded: "title" has already ended (<outcome — message> / stopped / archived). Use what it said rather than waiting on it.` |
| Circle (research R4) | `Nothing was recorded: waiting on "B" would close a circle: B waits on C, which waits on you.` |
| Minutes out of range | `Nothing was recorded: check_again_in_minutes has to be from 1 to 1440.` |

The existing refusals (closed token, unknown word, a question still waiting, no words) come
first and are unchanged.

Accepted note: `Recorded. You are blocked on "A" and "B"; you will be resumed when both have
finished.` or `… resumed in 25 minutes.` or `… until the person carries you on.`

## 3. Wire (helper → daemon)

`DaemonAPI.FinishTurnRequest` and `ReportOutcomeRequest` gain:

```swift
public var waitingOn: [String]?          // as written; resolved by the daemon
public var checkAgainInMinutes: Int?
```

Both are optional, so an older helper still relays a call, just without them. `FinishSink`
gains the two arguments. `Daemon/Sources/main.swift` passes them through unchanged.

## 4. Records seen by clients

`Agent.report.block` travels with the agent record in the existing `agentChanged` broadcast.
There is no new notification or method. Carry on uses the existing prompt method, sending
`Block.carryOnPrompt` as the person.

## 5. Resume prompt (`from: .app`)

Text as in research R10. It is queued at the back, and the queue is empty whenever a resume is
allowed, so it is the only thing queued.
