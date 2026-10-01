# Contract: Moving an Agent

## 1. Arguments of `finish_turn` (served by `agentsd mcp`, every agent)

**Changed 2026-09-29.** Moving was two tools, `enter_worktree` and `exit_worktree`. It is now
three optional arguments of `finish_turn`, because a move only ever happens when the turn
ends: asking on the call that ends the turn leaves no stretch of the turn in which edits land
in the folder being left, and an agent already calls `finish_turn` every turn, so the move
needs no briefing line of its own. The daemon keeps `agents/moveSelf` for helpers begun
before the change.

Offered to every agent on a runtime that can move, including one another agent started:
moving yourself isn't managing anyone. On a runtime that can't (`--no-move-tools`), the three
properties and the paragraph about them are left out of `finish_turn`'s schema, and a call
that sends them anyway is refused.

```json
"worktree": { "type": "string", "description": "Move into a git worktree of this project once this turn ends: a name for a new one, or the absolute path of one already there. Not with leave_worktree." },
"leave_worktree": { "type": "string", "enum": ["keep", "remove"], "description": "Move back to the project folder once this turn ends. keep leaves the worktree as it is; remove takes it away after you have left." },
"discard_changes": { "type": "boolean", "description": "Only with leave_worktree remove. Remove even though work would be lost." }
```

`worktree` starting with `/` is an existing worktree; anything else names a new one. There's
no longer a way to ask for a new worktree named from the title: the agent names it.

**Local refusals** (AppService, before the daemon; nothing is recorded):
- `worktree` and `leave_worktree` together.
- `leave_worktree` other than `keep` or `remove`.
- `discard_changes` without `leave_worktree` `remove`.
- Any of them on a runtime that can't move.

**Daemon refusals** (the whole call is refused: no report, no chips, no move):
- A move with `needs_answer` or `blocked`, or with `afterwards`: a move carries the agent on
  in the new folder, which none of those wants.
- Everything `askMove` refuses: not a repository; not a worktree of this repository; the
  worktree is missing; no commit to base one on; removal would lose `<what>`; removal refused
  for a worktree the app did not make or one another agent is in.

**Answers**: the report's own note, then the move's: "Moving to a new worktree like
`fix-login` when this turn ends. Nothing uncommitted comes with you (3 files here are
uncommitted). End your turn to move; you will be started again there to carry on."

A later `finish_turn` in the same turn without a move takes back a move the agent asked for
earlier (the last call is the whole account of the turn). A move the person asked for stays.

## 2. Daemon methods

### `agents/moveSelf`: from a helper begun before 2026-09-29

```swift
struct MoveSelfRequest: Codable { var token: String; var target: MoveTarget
                                  var removeLeft: Bool; var discardChanges: Bool }
// → MoveAnswer
```

The token names the agent. It's only valid from `agentsd mcp` (a token-bound connection, like
`agents/finishTurn`).

### `agents/move`: from a window

```swift
struct MoveRequest: Codable { var agentID: UUID; var target: MoveTarget?   // nil = cancel the waiting move
                              var removeLeft: Bool = false; var discardChanges: Bool = false }
// → MoveAnswer
```

- `ConnectionRole` classifies it like `agents/stop`, so strangers are refused.
- The phone may call it, but no phone UI does in this feature.

```swift
struct MoveAnswer: Codable {
    enum When: String, Codable { case now, afterTurn, nothing }
    var when: When
    var message: String      // what the tool returns, what a window may show
    var agent: Agent?        // the updated record, for a window
}
```

**Errors**: only 030's existing codes:
- `worktreeFailed` (-32028): not a repository, no commit yet, or git refused.
- `worktreeMissing` (-32029)
- `notAWorktree` (-32030): a foreign path, or removal of a worktree the app did not make.
- `worktreeInUse` (-32031): removal while another agent works there.
- `noSuchAgent` (existing), and a refusal for an archived agent.

## 3. Record and events

- `Agent.pendingMove` is set on ask and cleared on apply or cancel. Both go out through the
  usual `changed(agent)` broadcast, so windows and the phone see a waiting move with no new
  event.
- A successful apply calls `projectChanged(forAgentIn:)` (030), so project pages refresh their
  worktree lists.

## 4. Mac UI

On an agent's page, the prompt bar shows the **Worktree** capsule when the agent's project is a
git repository on this host:

| State | Capsule title | Choices |
|-------|---------------|---------|
| In the project folder | `Project folder` | Project folder ✓, New worktree, each existing worktree (with branch and agents, Missing disabled) |
| In a worktree | `<name>` | Project folder, New worktree, each existing worktree, with the current one ticked |
| Move waiting (turn running) | `Moving to <name>…` | the same, plus **Cancel move** |

- Choosing while idle moves at once. The chat line appears, and the files pane follows.
- A running terminal shows a strip: "This agent now works in `<name>`. [Open a terminal there]".
- Nothing about removal is offered from the capsule. Removal stays on the project page (030
  US3).
