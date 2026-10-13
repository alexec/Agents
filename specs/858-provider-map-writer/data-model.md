# Data model: An agent writes a provider's tool map or commands

## ProviderDraft (control plane, in memory)

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | Made by `providers/draftStart`. |
| `owner` | `ControlRouter.Caller` | The client session of the sheet. `control/providerDraft` goes only to it (R9). |
| `form` | `DaemonAPI.ProviderAdd` | The form so far: name, kind, command or URL, CLI, headers, an old map or config. |
| `secrets` | `[String: String]` | From the sheet, merged over the provider's own in Edit…. Memory only (FR-021). |
| `provider` | `ProviderID?` | Set in Edit…. |
| `runtimeID` | `String` | From the menu. |
| `host` | `HostID` | The host on the control plane's machine (R1). |
| `agent` | `UUID?` | The writing agent, once started. |
| `state` | `DraftState` | See below. |
| `steps` | `[DraftStep]` | Redacted. At most 100. |
| `draft` | `JSONValue?` | The last map or config sent with `send_draft` or checked. |
| `check` | `DraftCheck?` | The last check's result. |
| `question` | `DraftQuestion?` | Set in state `asking`. |
| `counts` | checks, tool calls | For FR-017. |
| `started` | `Date` | For the 5-minute limit, less the time spent asking and proving. |

**DraftState**: `reading` (tools or help), `writing`, `checking`, `asking`, `proving`,
`done(note:)`, `failed(reason:)`, `cancelled`. `done`, `failed` and `cancelled` end the draft:
the agent stops, the scratch folder is deleted, and the draft is dropped 10 minutes later.

**DraftStep**: `{at: Date, text: String, kind: read | help | check | ask | prove | note}`.

**DraftCheck**: `{passed: Bool, workspaces: [WorkspaceInfo]?, problem: String?}`. `workspaces`
is the list the check got, for the "✓ Listed 3: …" line.

**DraftQuestion**: `{id: UUID, kind: start | stop | check, workspace: String?, cost: String?,
text: String}`.

## ProviderRecord (changed)

| Field | Type | Notes |
|---|---|---|
| `writtenBy` | `WrittenBy?` | New. `{runtimeID: String, at: Date}`. Set by `providers/add` or `providers/update` when the request's `draft` id names a done draft and its map or config is equal to the draft's. Cleared by an update with a map the person wrote. |

## StartRequest (changed)

| Field | Type | Notes |
|---|---|---|
| `purpose` | `AgentPurpose?` | New. `.providerDraft(id: UUID)`. Nil for every other agent. Kept in the agent's record. |

## DaemonAPI.ProviderAdd (changed)

| Field | Type | Notes |
|---|---|---|
| `cli` | `String?` | New, for Your commands. Not kept in the record: the config holds the commands. |
| `draft` | `UUID?` | New. The draft this request accepts, for `writtenBy`. |
