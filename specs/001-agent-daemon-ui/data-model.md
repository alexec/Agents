# Data Model: Agent daemon and basic UI

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Everything here lives in `AgentsKit/Model` and is pure: no processes, no file handles, no protocol.
That is what makes the state machine cheap to test.

## Agent

The record of one conversation. Written to `~/Library/Application Support/Agents/agents/<id>/agent.json`.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Ours, minted on start, never changes (FR-012ca) |
| `runtimeId` | String | Which recipe started it: `claude`, `grok`, `copilot` |
| `cwd` | URL | Absolute. The folder the agent works in |
| `title` | String? | The runtime's own title for the session where it gives one, else the first line of the instruction (FR-007a) |
| `state` | AgentState | See below |
| `runtimeSessionId` | String? | The runtime's id for the current session. Replaced when a new session is started for this agent (FR-012cb). Nil before the first session exists |
| `startOptions` | StartOptions | What the user chose when starting it |
| `createdAt` | Date | |
| `lastActivityAt` | Date | Sorts the list |
| `endedReason` | EndedReason? | Set whenever the agent leaves running |
| `archivedReason` | ArchivedReason? | Only `byUser` in this feature, since nothing auto-archives (FR-012) |

Invariants:

- `id` is unique and is the directory name.
- `state == .archived` implies `archivedReason != nil`.
- `state == .stopped` implies `endedReason != nil`.
- `runtimeSessionId` may be nil in any state: an agent whose runtime lost its session is still an
  agent, and the next pick-up mints a new one.

## AgentState

Exactly one at a time (FR-010). Only `archived` is a resting place, and even it can be left.

| State | Means | Process alive? |
|---|---|---|
| `running` | A turn is in flight | Yes |
| `waitingOnUser` | The agent asked a permission question and is blocked on the answer | Yes |
| `finished` | A turn ended with `endTurn`. Idle, with everything it said kept | No, by decision 4 in the plan |
| `stopped` | The user stopped it, its process died, or a turn ended short | No |
| `archived` | Put away by the user | No |

### Transitions

```text
                    start
                      │
                      ▼
   ┌──────────────► running ──────────────┐
   │                │   ▲                 │
   │   permission    │   │ answer          │ turn ends
   │   asked         ▼   │                 ▼
   │           waitingOnUser        ┌──────┴───────┐
   │                │               │              │
   │                │ stop     endTurn        limit/refusal/
   │                ▼               │         cancel/crash
   │             stopped ◄──────────┼──────────────┘
   │                │               ▼
   │                │           finished
   │                │               │
   │   prompt       │   archive     │  archive
   └────────────────┴───────────────┴──────► archived
                                                │
                                                │ prompt
                                                ▼
                                            running
```

Rules the transitions encode:

- A prompt from any non-running state starts a turn: stopped and archived agents are picked up, not
  copied (FR-012b, US5).
- `finished` is reached only by `endTurn`. Every other ending is `stopped` with a reason (FR-012a).
- Archiving a running or waiting agent stops it first (FR-013).
- Nothing moves to `archived` without the user (FR-012).

## EndedReason

Taken from the turn's stop reason, plus the two endings the protocol does not report.

| Case | Source |
|---|---|
| `endTurn` | `stopReason: end_turn`. The only one that leads to `finished` |
| `maxTokens` | `stopReason: max_tokens` |
| `maxTurnRequests` | `stopReason: max_turn_requests` |
| `refusal` | `stopReason: refusal` |
| `cancelled` | `stopReason: cancelled`, after the user stopped it |
| `processDied` | The process went without a stop reason: a crash |
| `daemonGone` | Found dead on daemon start: logout, restart, or the daemon was killed (FR-019b) |
| `unrecognised` | A stop reason this app has never heard of. Added during implementation: a runtime shipping a new one must be recorded rather than rounded to the nearest reason we know, and the raw string goes in a `runtimeNote` beside it |

## TranscriptEntry

Appended to `transcript.jsonl`, one JSON object per line, never rewritten. The order in the file is
the order things happened.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `at` | Date | |
| `kind` | Kind | Below |
| `payload` | Kind-specific | |

| Kind | Carries |
|---|---|
| `userMessage` | What the user typed |
| `agentMessage` | A chunk the agent produced, with the runtime's message id so chunks join up |
| `agentThought` | Reasoning where the runtime sends it separately |
| `toolCall` | Title, kind, status, and what it touched |
| `toolCallUpdate` | A status change to a `toolCall` already recorded |
| `plan` | The agent's plan, where it sends one |
| `permissionAsked` | The question and its options |
| `permissionAnswered` | Which option, and that the user chose it |
| `optionChanged` | An option the user or the runtime changed mid-session |
| `stateChanged` | The new state and, where there is one, the reason |
| `runtimeNote` | Ours, not the agent's: "runtime starting", "session resumed", "runtime could not give the session back" |

`runtimeNote` matters more than it looks: it is how the record stays honest across the gaps where
there is no agent process at all.

## StartOptions

What the user chose in the start form, kept so a pick-up can start the runtime the same way.

| Field | Type | Notes |
|---|---|---|
| `values` | [String: String] | Keyed by the advertised option `id`, e.g. `model` → `gpt-5.6-terra` |

There is nothing else: the free-text argument field was dropped (FR-005c).

Options are applied to a live session by the set-option call rather than passed at launch, because
they are advertised by `session/new` and not before (plan, decision 7).

## ConfigOption

Not ours: the shape the runtime advertises, kept as it arrives. The form is generated from it and no
field is interpreted beyond these.

| Field | Type | Notes |
|---|---|---|
| `id` | String | `model`, `mode`, `reasoning_effort`, `effort`, `fast`, `allow_all`, … |
| `name` | String | Shown |
| `description` | String? | Shown where given |
| `category` | String? | `model`, `mode`, `thought_level`, `permissions`, `model_config`, … Orders the form |
| `type` | String | `select` is the only one all three use today. An unknown type is skipped, not guessed |
| `currentValue` | String? | |
| `options` | [Choice] | `value`, `name`, `description?` |

## PermissionRequest

A question the agent is blocked on (FR-009a). Held by the daemon, answered by the user, and the
answer is a protocol reply, not a message.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Ours |
| `agentId` | UUID | |
| `requestId` | JSON-RPC id | What we must reply to |
| `toolCall` | ToolCall | What it wants to do |
| `options` | [PermissionOption] | `optionId`, `name`, `kind` (allow once, allow always, reject once, reject always) |
| `askedAt` | Date | |

Invariants: at most one outstanding request per agent, because the agent is blocked while it waits.
An unanswered request survives the app closing and is never answered by us (FR-009b).

## Runtime

A launch recipe, not an installed binary (FR-003).

| Field | Type | Notes |
|---|---|---|
| `id` | String | `claude`, `grok`, `copilot` |
| `name` | String | Shown |
| `launch` | Launch | The executable to resolve and its arguments |
| `availability` | Availability | `available(URL)`, `missing(lookedIn: [String])`, `needsSignIn(authMethods:, fixCommand:)` |
| `supportsResume` | Bool | Read from `sessionCapabilities`, not assumed |

Recipes in this feature:

| id | Resolve | Arguments |
|---|---|---|
| `claude` | `npx` | `-y @agentclientprotocol/claude-agent-acp` |
| `grok` | `grok` | `agent stdio` |
| `copilot` | `copilot` | `--acp` |

## On disk

```text
~/Library/Application Support/Agents/
├── daemon.sock                 # The app connects here
├── daemon.lock                 # flock, held by the one daemon
├── daemon.log                  # Rolled, for when something goes wrong
└── agents/
    └── <agent uuid>/
        ├── agent.json          # Written whole, atomically, on every change
        └── transcript.jsonl    # Appended, never rewritten
```

The daemon is the only writer. The app never reads this directory: it asks the daemon, so there is
one reader of the truth and no file locking between processes to get wrong.
