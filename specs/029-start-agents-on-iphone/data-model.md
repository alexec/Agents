# Data Model: Starting agents on iPhone

What this feature adds or changes, and nothing else. Types are in `Packages/AgentsKit`
unless named otherwise.

## Changed

### `DaemonAPI.StartRequest` (AgentsKitCore)

| Field | Type | New | Meaning |
|-------|------|-----|---------|
| `requestID` | `UUID?` | yes | Minted once per send by the caller and reused on every retry of that send. `nil` from callers that do not retry (workflows, `startHelper`, older Macs). |

Decoded with `decodeIfPresent`, so an older caller that leaves it out is unchanged.

### `Agent` (AgentsKitCore)

| Field | Type | New | Meaning |
|-------|------|-----|---------|
| `startRequestID` | `UUID?` | yes | The `requestID` of the start that made this agent. Written on the first save, never changed. Lets a phone that lost the reply find the agent in `agents/list`. |

Encoded with `encodeIfPresent`, like `startedByAgent`, so records written before this feature
still decode.

### `DaemonCore.Draft` (AgentsKit, daemon only)

| Field | Type | New | Meaning |
|-------|------|-----|---------|
| `connection` | `UUID?` | yes | The connection that asked for it. `nil` for drafts the daemon makes itself (workflows). |
| `orphanedAt` | `Date?` | yes | Set when that connection goes; the draft is ended once the grace period has passed and cleared if the same device asks for it again. |

Rules:

- A draft is ended by `agents/discardDraft`, by being used or replaced by `agents/start`, or by
  its connection being gone for longer than the grace period (30 s).
- Ending a draft ends its runtime session. That is `endDraft`, which already exists.

## New

### Mode memory (daemon)

One file in the root's Application Support folder, beside the option cache:
`modes.json`.

```text
{ "<runtimeID>": { "mode": <JSONValue>, "chosenAt": <ISO-8601 date> } }
```

| Rule | Why |
|------|-----|
| One entry per runtime; a runtime never used has none | Same as the `UserDefaults` keys it replaces |
| Written on `agents/start` when the start's `startOptions` hold a value for the runtime's mode option | The start is what "last used" means |
| Written on `agents/setOption` when the option is the agent's mode option | The Mac already treats changing a live agent's mode as saying what you want next time |
| Written by `modes/import` only where the runtime has no entry | Carrying the Mac's memory over must never overwrite a newer choice (research §2) |
| An entry that no longer decodes is treated as absent and left in the file | Same rule as `AppModel.rememberedMode` today |
| A remembered value the runtime no longer offers is dropped at read time by `ModeMemory.startingValue`, not deleted | A runtime may offer it again |

Which option is the mode is `ModeMemory.modeOption(in:)`, unchanged.

### Default runtime (AgentsKitCore)

`AgentsModel.defaultRuntimeID(available: [String]) -> String?`, moved from
`AppModel.defaultRuntimeID`. The rule is unchanged: the runtime of the most recently active
agent that is still available, else the first available one. Both apps call it.

### Phone start state (Remote, in memory)

Held by `RemoteModel` while the start screen is up. Not persisted except for the draft.

| Field | Type | Meaning |
|-------|------|---------|
| `project` | `URL` | The project folder the screen was opened on |
| `runtimeID` | `String?` | Chosen runtime; seeded from the default runtime |
| `draftID` | `UUID?` | From `agents/options`; discarded on runtime change or dismissal |
| `options` | `[ConfigOption]` | What the runtime offers, drawn with `PromptControlsState.drawable` |
| `chosen` | `[String: JSONValue]` | Choices made; seeded from each option's `currentValue`, and the mode from mode memory |
| `optionsState` | `loading \| ready \| failed(String)` | For FR-008 and US2 scenarios 4 and 7 |
| `pendingRequestID` | `UUID?` | Set when send is pressed, cleared when the start is settled either way |

### Phone draft (existing `DraftStore`, new use)

Key: `DraftKey.newAgent(folder: project)`. Holds the prompt and attachments; the size cap and
the dropped-inline-data flag are the store's own. Cleared on a settled start (research §9).

### Attachment limits (Remote)

| Rule | Value |
|------|-------|
| Picture long edge after downscaling | 2048 px, JPEG |
| Total attached by value per start | 900 KB, below the relayed link's 1 MB record ceiling |
| Files accepted from Files | Text (UTF-8 decodable) as embedded resource; images as pictures; anything else refused |
