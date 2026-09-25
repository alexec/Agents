# Daemon API changes: 033

One new method. Nothing existing changes shape.

## `files/mention` (new)

Files under an agent's folders that match what follows an `@`, found on the Mac.

**Request**
```json
{ "agentID": "UUID", "term": "Transc" }
```

**Result**
```json
[ { "path": "/Users/…/App/Sources/Chat/Transcript.swift",
    "relativePath": "App/Sources/Chat/Transcript.swift" } ]
```

**Rules**
- Searches `[agent.cwd] + agent.additionalDirectories` with `FileMention.matching`, using the
  same cap and limit (30) as the Mac.
- An empty term returns `[]` without walking.
- Unknown agent: error `-32602`, "No such agent", the same as `agents/prompt`.
- Read-only. Nothing is broadcast.

## Used by the phone for the first time (unchanged)

| Method | For |
|--------|-----|
| `agents/setOption` | a control changed in the chat |
| `agents/unqueue` | taking a queued prompt back |
| `agents/setCeiling` | "Let this one go on" |
| `agents/prompt` with `attachments` | attachments from the chat |
| `agent/terminalOutput` (notification) | a command's output in a call's detail |
