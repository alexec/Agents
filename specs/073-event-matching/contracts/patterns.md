# Contract: a pattern in its three forms

## In a workflow file

```yaml
on:
  - agent.finished:
      labels: bug
      afterwards: park
  - agent.finished:
      outcome: [done, nothing_to_do]   # inline list
  - agent.failed:
      reason:                          # block list
        - allowance_spent
        - rate_limited
```

A detail with a mapping under it, or a list holding a mapping, is still refused:
`The "outcome" under "agent.finished" should be one value or a list of values`.

## In `wait_for_event`

```json
{"events": ["agent.finished"], "where": {"labels": "deploy", "outcome": ["done", "nothing_to_do"]}}
```

- A `where` value may be text, a number, true or false, or a list of those.
- Anything else refuses the wait with:
  `The "outcome" in where is an object; a value is text, a number, true or false, or a list of those.`

## On the wire (workflows)

- `{"unrecognised": {"name": "agent.finished", "keys": {"outcome": ["done", "nothing_to_do"]}}}`
- A single value stays a string, as today.

## Problems (`EventPatternProblem.message`)

| Case | Sentence |
|---|---|
| bad key | `agent.finished carries afterwards, agent, labels, outcome, runtime, started_by; "lables" is not one of its details.` |
| bad value | `outcome on agent.finished is one of done, nothing_to_do, needs_answer, partly_done, stuck, blocked; "complete" is not one of them.` |
| old words with no code | the bad-value sentence, quoting the old words |

- A workflow file shows the same sentence as its problem.
- For a list, the sentence names the first wrong value.

## Words

| Form | T1 example | T4 example |
|---|---|---|
| `summary` | `An agent in this project ended a turn having done its work (labelled bug, and parked)` | `… (done or nothing to do)` |
| `label`, the status line and a run's cause | `agent.finished afterwards park labels bug` | `agent.finished outcome done\|nothing_to_do` |
| capsule | `afterwards: park`, `labels: bug` | `outcome: done \| nothing_to_do` |
| `asTrigger` | `afterwards: park` / `labels: bug` lines | `outcome: [done, nothing_to_do]` |

Phrases that begin "and" (`and parked`, `and not parked`) go after the others.
