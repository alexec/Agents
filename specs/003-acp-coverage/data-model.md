# Data model: Complete ACP coverage

Everything here lives in `AgentsKit`. Fields marked **new** are added by this feature; everything
else is from 001 and is listed only where it changes. Every new field on a stored record is optional
on read, so a record written by 001 still loads.

## Content

### ContentBlock (new)

What a message is made of, in both directions. The protocol has always sent this; we flattened it to
a string.

| Case | Fields | Notes |
|---|---|---|
| `text` | `text: String` | |
| `image` | `data: Data`, `mimeType: String`, `uri: String?` | Sent only where the runtime advertises `image` |
| `audio` | `data: Data`, `mimeType: String` | Sent only where the runtime advertises `audio`. No runtime here does |
| `resourceLink` | `uri: String`, `name: String`, `mimeType: String?`, `size: Int?` | Baseline. Needs no capability |
| `resource` | `uri: String`, `text: String?`, `blob: Data?`, `mimeType: String?` | Sent only where the runtime advertises `embeddedContext` |
| `unknown` | `raw: JSONValue` | Kept, never dropped, drawn as raw |

Rules:
- A block of a kind the app does not know MUST decode to `unknown` and MUST NOT fail the message.
- `plainText` on a list of blocks is the text blocks joined. It is stored alongside the blocks so
  records stay readable and searchable.

### Attachment (new)

A `ContentBlock` the user added to a prompt before sending, plus what the composer needs to draw it.

| Field | Type | Rules |
|---|---|---|
| `id` | UUID | |
| `block` | ContentBlock | image, resourceLink or resource only |
| `displayName` | String | File name, or "Screenshot" for a pasted image |
| `byteCount` | Int? | Shown when known |

Rules:
- An attachment whose block kind the runtime does not advertise MUST be refused before sending, with
  the reason.
- Attachments belong to the message they were sent with and are stored in the transcript entry.

## Tool calls

### ToolCallContent (new)

| Case | Fields |
|---|---|
| `content` | `block: ContentBlock` |
| `diff` | `path: String`, `oldText: String?`, `newText: String` |
| `terminal` | `terminalID: String` |
| `unknown` | `raw: JSONValue` |

### ToolCall (changed)

| Field | Change |
|---|---|
| `name` | **new**, the protocol's `name`, separate from `title` |
| `content` | **new**, `[ToolCallContent]`, appended by updates rather than replaced |
| `locations` | **new**, `[ToolCallLocation]` of `path` and optional `line` |
| `rawInput` | **new**, kept separately so a completion update cannot lose it |
| `rawOutput` | **new** |
| `raw` | kept, for anything unmodelled |

Merge rules (this is where the audit found a bug):
- Each field is taken from an update only when the update carries it.
- `content` is appended, not replaced. `locations` is replaced when present.
- `rawInput` and `rawOutput` are independent; neither overwrites the other.

## Usage

### Usage (new)

| Field | Type | Notes |
|---|---|---|
| `used` | Int | Tokens in the context now |
| `size` | Int | Context window size. Zero means unknown, and the meter is hidden |
| `cost` | Cost? | Only if the runtime sent one |
| `at` | Date | |

### TurnUsage (new)

Written into the transcript when a turn ends: `inputTokens`, `outputTokens`, `totalTokens`,
`thoughtTokens?`, `cachedReadTokens?`, `cachedWriteTokens?`, `cost?`.

### Cost (new)

`amount: Decimal`, `currency: String`. Shown as sent. No conversion, no estimation, no summing
across currencies: a total is per currency.

Rules:
- `fraction` is `used / size`, nil when `size` is zero.
- "Close to full" is `fraction >= 0.85`. One constant, in the kit, with a test.

## Plans

### Plan (new)

| Field | Type |
|---|---|
| `planID` | String? (absent for the unidentified `plan` update) |
| `entries` | `[PlanEntry]` |
| `state` | `.current` or `.withdrawn` |

### PlanEntry (new)

`content: String`, `priority: .high/.medium/.low`, `status: .pending/.inProgress/.completed`.

Rules:
- A `plan` update replaces the current unidentified plan.
- A `plan_update` carrying a `planID` replaces the plan with that id, or adds it.
- A `plan_removed` marks that plan `.withdrawn`. It is kept on the record, not deleted.

## Elicitation

### ElicitationRequest (new)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Ours |
| `elicitationID` | String? | Theirs, when the request carries one |
| `agentID` | UUID | |
| `mode` | `.form(ElicitationSchema)` or `.url(URL, description: String?)` | |
| `scope` | `.session` or `.request` | Whether the answer outlives the turn |
| `askedAt` | Date | |

### ElicitationSchema (new)

An object of named properties, each one of:

| Kind | Fields | Validation |
|---|---|---|
| `string` | `format?` (email, uri, date, date-time), `minLength?`, `maxLength?`, `enum?` | Against format and length |
| `number` / `integer` | `minimum?`, `maximum?` | Range, and integer-ness |
| `boolean` | | |
| `multiSelect` | `items` (plain strings or titled values), `minItems?`, `maxItems?` | Count |

Each property has `title?`, `description?`, `required: Bool`, `default?`.

Rules:
- A property of a kind the app cannot draw makes the whole form undrawable, and the app declines the
  request rather than sending a partial answer.
- The answer MUST validate against the schema before it is sent.
- An unanswered request survives the window closing, like a permission question.

## Serving the agent

### ServedRequest (new)

Recorded in the transcript so the user can see what an agent asked of the app.

| Field | Type |
|---|---|
| `kind` | `.readFile(path)`, `.writeFile(path, byteCount)`, `.runCommand(command, args)` |
| `outcome` | `.served`, `.refused(reason)`, `.failed(message)` |
| `at` | Date |

### FolderScope (new)

The folders an agent may reach: its `cwd` plus `additionalDirectories`.

Rules, all in one function with its own tests:
- A path is resolved, with symlinks followed, before it is compared.
- A path is allowed only when it is inside one of the folders after resolution.
- A path that does not exist yet is allowed only when its nearest existing parent is inside.
- Refusal is the default for anything that cannot be resolved.

### Terminal (new)

| Field | Type |
|---|---|
| `id` | String, given to the agent |
| `agentID` | UUID |
| `command`, `args`, `cwd`, `env` | As requested, `cwd` inside the folder scope |
| `output` | Ring buffer with a byte cap, truncation flagged |
| `exit` | `exitCode: Int32?`, `signal: String?` |

Rules:
- Every terminal is a child of the daemon.
- Stopping an agent kills its terminals. The daemon kills all of them before exiting.
- `outputByteLimit` is a constant in the kit; output beyond it drops the oldest bytes and sets
  `truncated`.

## Runtimes

### RuntimeAccount (new)

Per runtime, not per agent.

| Field | Type |
|---|---|
| `runtimeID` | String |
| `state` | `.ready`, `.needsSignIn`, `.unknown` |
| `authMethods` | `[AuthMethod]` with `id`, `name`, `description`, and `terminalCommand?` |
| `canLogOut` | Bool |
| `providers` | `[Provider]`, `currentProviderID: String?` |

### Provider (new)

`id`, `name`, `protocol` (anthropic, openai, azure, vertex, bedrock, or whatever else is sent),
`isConfigured: Bool`.

### RuntimeSession (new)

What `session/list` returns, before it is anything of ours.

`sessionID`, `cwd`, `additionalDirectories`, `title?`, `updatedAt?`, and `isHeld: Bool` for whether
an agent in this app already has it.

### MCPServer (new)

`name`, and one of `.stdio(command, args, env)`, `.http(url, headers)`, `.sse(url, headers)`.
Attached per agent, sent on `session/new`. A server that fails is reported against the agent and
does not stop it.

## Changed from 001

### ConfigOption

| Field | Change |
|---|---|
| `kind` | **new**: `.select([ConfigChoiceGroup])`, `.boolean`, `.unsupported(String)`. Replaces the bare `type` string for rendering |
| `options` | Now groups. A flat list becomes one unnamed group |

Decoding rules:
- A group without a name, a choice without a value, an unknown type: each costs that one element.
- Nothing in the options list may fail the session. This is the audit's one agent-losing bug.

### Agent

New fields, all optional on read: `usage`, `plans`, `additionalDirectories`, `mcpServers`,
`lastTurnUsage`, `costToDate`.

### TranscriptEntry.Kind

New cases: `planUpdated(Plan)`, `usageRecorded(TurnUsage)`, `servedRequest(ServedRequest)`,
`elicitationAsked(ElicitationRequest)`, `elicitationAnswered(id, summary)`, `compaction(status,
summary: [ContentBlock])`. `userMessage` and `agentMessage` gain `blocks: [ContentBlock]` alongside
their text.

Rule: an entry kind read from disk that this version does not know is kept and skipped when drawing.
A newer app writing the file must not make an older one lose the transcript.
