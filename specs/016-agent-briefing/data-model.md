# Data Model: What Every Agent Is Told

Nothing here is stored, encoded, or sent to a window. "Data model" means three things held in memory
by the daemon and one string that leaves it.

---

## Briefing

`enum Briefing` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift`. A namespace, not
a value — there is one briefing and it has no instances.

| Member | Type | What it is |
|---|---|---|
| `suggestions` | `static let String` | End a turn by offering what to ask next. Names `AppTool.suggestPrompts`. |
| `escalation` | `static let String` | Put a decision that is the person's to the person. Names no tool. |
| `workflows` | `static let String` | Standing arrangements belong to this app. Names `AppTool.manageWorkflows`. Carries its own restraint. |
| `lines` | `static var [String]` | Which lines go, and in what order. |
| `text` | `static var String` | `lines` joined by a blank line. What `beginTurn` appends. |

**Rules**

- Every line is written as the person speaking — "things I might want to ask", not "things the person
  might want to ask" — because it is sent inside the person's turn.
- Where a line names a tool it names it through `AppTool`, never as a string literal, so a renamed
  tool cannot leave the words behind (FR-007).
- No line names a tool the agent does not have (FR-008). Today that is trivially true; 015 is what
  makes it a real constraint, and `lines` is the seam where it becomes `lines(for:)`.
- `lines` is the only place the order is decided, and the only place a new line is added (FR-018).

**Order, and why**: `suggestions`, `escalation`, `workflows`. First the one that fires on every turn
and is already proven. Then the one whose failure costs the most — a guess is work done wrong, and an
agent's strongest instinct is to finish rather than ask, so it needs the position nearest the front
that it can get. Last the one that is conditional on the person asking for something recurring, which
most turns never do. 014's `outcome` joins after `escalation` and before `workflows`.

---

## Line

Not a type — a convention about what each string in `lines` contains. A line that has only half of
this is the shape that fails.

| Part | Why it is required |
|---|---|
| What to do | The instruction. Without it the tool goes uncalled, which is the whole finding. |
| What not to do instead | The failure has a shape: a crontab, a guess, a question buried in a reply. Naming it is what displaces it. |
| Why it is worth doing | Only needed where the app knows something the agent cannot: that a question outlives the window and reaches a phone. |
| The exact tool name, or none | Ours: named through `AppTool`. The runtime's: named not at all. |

---

## needsBriefing

`var needsBriefing: Set<UUID>` on `DaemonCore` — today's `needsSuggestionAsk`, renamed. Agents whose
next prompt carries the block.

| Transition | Where | Why |
|---|---|---|
| Inserted when a conversation is made | `start` | First prompt of the conversation (FR-010) |
| Inserted when a new conversation replaces a lost one | the `session/new` fallback in `ensureSession` | The history that held it is gone (FR-011) |
| **Not** inserted when a conversation is resumed | the `session/load` path | The runtime replays its own history (FR-012) |
| Removed when the prompt goes | `beginTurn` | Once, not every turn |

It is deliberately in memory and not on the record. A daemon that restarts has, by definition, either
resumed the conversation — in which case the runtime still holds the words — or lost it, in which
case the fallback re-inserts. There is no third case that persistence would rescue.

---

## The block that leaves

Appended to the prompt as one `ContentBlock.text`, after the person's own blocks.

```text
prompt = [ …the person's blocks… ] + [ .text(Briefing.text) ]
```

Two properties matter and both come from the order of operations in `beginTurn`, which records the
turn **before** it appends:

- **The transcript holds the person's words alone** (FR-015). What is recorded is `blocks`; what is
  sent is `outgoing`. They are different variables on purpose.
- **Deleting the append leaves everything working** (FR-017). The briefing is what makes the
  behaviour happen on its own; it is not what makes it possible.

---

## What has no model here

- **No stored briefing.** Nothing under the daemon's root grows a file or a field.
- **No per-project or per-agent variation.** Every agent is told the same things.
- **No record of having been briefed**, beyond the in-memory set above.
- **Nothing on the wire to a window.** The phone and the Mac app never learn this happened, and
  neither draws it.
