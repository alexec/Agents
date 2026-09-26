# Contract: Moving an Agent

## 1. App tools (served by `agentsd mcp`, every agent)

Offered to every agent, including one another agent started: moving yourself isn't managing
anyone. They're listed after the event tools. Neither name ends with another tool's name
(036's `release_resource` lesson).

### `enter_worktree`

```json
{
  "name": "enter_worktree",
  "description": "Move yourself into a git worktree of this project: a new one, or one that is already there. Use it on your own judgement when the work turns into a change that should be on its own branch, or when asked. The move happens when your turn ends, so finish your turn soon after calling it; edits you make before then land where you are now. Nothing uncommitted comes with you. A new worktree starts from the commit your current folder has checked out, so commit first what you want to bring. After the move you are started again in the new folder to carry on.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "name": { "type": "string", "description": "A name for a new worktree. Leave out for one named from this conversation's title. Not with path." },
      "path": { "type": "string", "description": "The absolute path of an existing worktree of this repository to move into. Not with name." }
    }
  }
}
```

### `exit_worktree`

```json
{
  "name": "exit_worktree",
  "description": "Move yourself back to the project folder from the worktree you are in. keep leaves the worktree and its branch as they are; remove takes the worktree away after you have left, and its branch if the app made it and it is merged. Remove is refused for a worktree the app did not make or another agent works in, and, unless discard_changes is true, when anything in it is uncommitted or unmerged: ask the person before discarding. The move happens when your turn ends.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "action": { "type": "string", "enum": ["keep", "remove"] },
      "discard_changes": { "type": "boolean", "description": "Only with remove. Remove even though work would be lost." }
    },
    "required": ["action"]
  }
}
```

**Local refusals** (AppService, before the daemon):
- `name` and `path` together.
- A `path` that doesn't start with `/`.
- `action` missing or unknown.
- `discard_changes` without `remove`.

**Answers** (text, from the daemon):
- Accepted mid-turn: "Moving to a new worktree like `fix-login` when this turn ends. Nothing
  uncommitted comes with you (3 files here are uncommitted). End your turn to move."
- Accepted, and nothing will follow: "You are not in a worktree; nothing to do."
- Refused, with the reason, and nothing stored: not a repository; not a worktree of this
  repository; the worktree is missing; removal would lose `<what>` (with the list of files and
  commits); removal refused for a worktree the app did not make or one another agent is in.

## 2. Daemon methods

### `agents/moveSelf`: from the tool relay

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
