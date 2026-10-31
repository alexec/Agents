# Data model: Desktop control

All wire types go in `Packages/Wire/daemon.schema.json` first; `scripts/wire.sh gen` makes
the Go and the TypeScript; `WireSchemaTests` says what to write in Swift by hand (#1135).
The decisions behind each shape are in `research.md`.

## DesktopControlSettings (new, person-level)

Kept at `<settings>/desktop-control.json`, read the way `sandbox.json` is (research R5).

| Field | Type | Unset means |
|---|---|---|
| `enabled` | boolean | `false` (Off) |

## DesktopControlRefusal (new)

Returned from `drive_screen` while Off or while Accessibility is not granted (FR-004,
FR-005).

| Field | Type | Notes |
|---|---|---|
| `reason` | `"off" \| "accessibilityNotGranted"` | which card to show |
| `words` | string | names the rule and where to turn it on, or where to grant Accessibility |

## DriveScreenCall (the `drive_screen` app tool's params, research R6)

| Field | Type | Notes |
|---|---|---|
| `app` | string | the running app's name or bundle id, as `ui.swift`'s pid-finding already resolves one |
| `action` | `"screenshot" \| "click" \| "type" \| "key" \| "read"` | |
| `label` | string? | an AX label to find, for `click` (as `ui.swift find`/`press`) |
| `x`, `y` | number? | screen-point `click`, when no label fits |
| `text` | string? | for `type` |
| `keyName` | string? | for `key` (for example `return`, `tab`, `escape`) |

Every call implicitly takes the `screen` lease first if the agent does not already hold it
(research R4); every call's narration is its own ACP tool-call title (research R7), so no
separate narration field is sent back.

## DesktopControlState (live, kept per agent while the `screen` lease is held; never persisted beyond the lease's own lifetime)

| Field | Type | Notes |
|---|---|---|
| `agentID` | string | |
| `app` | string | the app last named in a `drive_screen` call |
| `lastNarration` | string | the transcript's own last live line, mirrored here so a client that opens the session mid-run has something to show before the next step arrives |
| `paused` | boolean | true the moment FR-007 fires |
| `pausedAt` | `WireDate`? | present only while `paused` |

## LiveFrame (never stored, research R7)

One of:

- `{agentID, image: string (data), capturedAt: WireDate}` — a downscaled screenshot.
- `{agentID, locked: true, capturedAt: WireDate}` — the screen is locked (FR-012); no
  `image` field is ever present in this case.

Held only for as long as it takes to reach a showing client; never written to `d.record`,
the project folder, or `<root>`.

## Events (new)

| Event | Raised when | Details |
|---|---|---|
| `desktopControl.paused` | FR-007 fires | `{agentID, app}` |
| `desktopControl.resumed` | the person chooses **Resume** | `{agentID}` |
| `desktopControl.takenOver` | the person chooses **Take Over** | `{agentID}` |

`lease.granted` (`"screen"`) is reused as is for the queued case (research R1 of spec 036;
no change).

## State transitions

### The `screen` lease, while `drive_screen` is in use

```text
free ──(drive_screen's first call)──▶ held by agent A
held by A ──(A stops calling for longer than the turn, or the turn stops)──▶ free
held by A ──(the person chooses Take Over)──▶ free; desktopControl.takenOver
held by A ──(another agent calls drive_screen)──▶ held by A; the second agent queued, waits on lease.granted
held by A ──(lease expires, docs/explanation/leases.md)──▶ free; A must call drive_screen again to resume driving
```

### Pause on touch (DesktopControlState.paused)

```text
not paused ──(a real mouse/key event with no agents-drive marker, research R2)──▶ paused; desktopControl.paused; every showing client offers Resume/Take Over
paused ──(the person chooses Resume)──▶ not paused; desktopControl.resumed; the current action continues
paused ──(the person chooses Take Over)──▶ the screen lease is released (see above); the agent's turn is told the person took over
```

### The live tile, per showing client

```text
no tile ──(the client opens a session holding the screen lease)──▶ tile shown: last narration + last frame (or "Mac is locked")
tile shown ──(a new LiveFrame or transcript narration arrives, ≤ 2 s after an action, ≤ 5 s idle, FR-011)──▶ tile refreshed
tile shown ──(the lease is released)──▶ tile removed; the session reverts to an ordinary running/finished turn
```

## Sizes

`desktop-control.json` is one boolean, under 100 bytes. `DesktopControlState` is one small
record per agent holding the lease, in memory only. A `LiveFrame` is well under 1 MB
(research "Sizes"); none are kept once delivered.
