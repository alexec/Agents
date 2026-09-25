# Data Model: One Chat on Every Screen

Nothing new is stored. Three pieces of state move from the Mac's `AppModel` into the shared
`AgentsModel`, and one wire shape is added.

## Moved into `AgentsModel` (AgentsKitCore)

### PendingOption
The choice made on a control that the daemon has not yet confirmed.

| Field | Type | Rule |
|-------|------|------|
| value | JSONValue | What was chosen |
| sequence | Int | Which write this was. Only the latest write for an (agent, option) may clear it |

Held as `[agentID: [optionID: PendingOption]]`. Read by
`chosenOption(optionID, for: agent, advertised:)` in this order: pending, then
`agent.startOptions`, then the advertised current value. It is cleared when that write's call
returns, whether the call succeeded or failed.

### Terminal output
`terminalOutput: [terminalID: String]`, appended from `agent/terminalOutput` notifications, and
capped per terminal at the Mac's existing cap, keeping the tail.

### Ceiling to go on
`ceilingToGoOn(for agent: Agent, under limits: CostLimits) -> Cost`: the agent's spend plus one
more step of its ceiling, or of the app-wide limit when it has no ceiling of its own.

## Wire

### FileMentionDTO (new, in `DaemonAPI`)
| Field | Type |
|-------|------|
| path | String, the absolute path on the Mac |
| relativePath | String, as shown |

## Phone-only view state

### Draft (existing `Draft`, `DraftKey.agent(id)`)
Text plus attachments, kept per conversation on the device. It is restored when the
conversation opens again, cleared on a settled send, and never shown in another conversation.
