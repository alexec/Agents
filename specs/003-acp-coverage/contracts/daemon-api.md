# Contract: what the app asks the daemon

Extends `specs/001-agent-daemon-ui/contracts/daemon-api.md`. Same transport: line-delimited
JSON-RPC 2.0 over the Unix socket. Only additions and changes are listed.

## Changed calls

### `agent.start`

Gains `attachments`, `additionalDirectories` and `mcpServers`. `prompt` becomes a list of content
blocks rather than a string; a bare string is still accepted, so an older app keeps working.

### `agent.prompt`

Gains `attachments`. Same rule about the bare string.

### `agent.options`

Options now carry a kind (`select` with groups, `boolean`, or unsupported) rather than a bare type
string.

## New calls

| Method | Params | Result |
|---|---|---|
| `runtime.account` | `runtimeID` | The account: ready or needs sign-in, its auth methods, whether it can log out, its providers |
| `runtime.authenticate` | `runtimeID`, `methodID` | Ready, or what went wrong. A terminal method returns the exact command instead of running it |
| `runtime.logout` | `runtimeID` | The agents this stopped |
| `runtime.setProvider` | `runtimeID`, `providerID` | The account again |
| `sessions.list` | `runtimeID`, `cwd` | Sessions the runtime holds, each flagged with whether an agent here already has it |
| `sessions.adopt` | `runtimeID`, `sessionID`, `cwd` | The new agent |
| `agent.fork` | `agentID` | The new agent |
| `sessions.delete` | `runtimeID`, `sessionID` | Nothing. Refuses unless the caller passed `confirmed: true` |
| `agent.answerElicitation` | `agentID`, `requestID`, `action`, `content?` | Nothing |
| `agent.terminals` | `agentID` | The terminals the daemon is running for that agent |
| `agent.usage` | `agentID` | The current context usage and the cost so far |

## New notifications

| Notification | Carries |
|---|---|
| `agent.usageChanged` | `agentID`, used, size, cost |
| `agent.planChanged` | `agentID`, the plan |
| `agent.elicitationAsked` | `agentID`, the request |
| `agent.elicitationWithdrawn` | `agentID`, request id |
| `agent.terminalOutput` | `agentID`, terminal id, the new bytes |
| `runtime.accountChanged` | `runtimeID`, the account |

## Rules

- Every new call is refused with a reason when the runtime did not advertise the capability behind
  it. The app hides the action, and the daemon refuses it anyway.
- `sessions.delete` is the only irreversible call in the API. It requires `confirmed: true` and
  never happens as a side effect of archiving.
- A served file request and a terminal are the daemon's, never the app's. The app sees them as
  transcript entries and notifications.
- An agent record written by 001 loads. A field this version does not know is preserved on write.
