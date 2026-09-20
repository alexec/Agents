# Contract: The daemon

Extends [008's daemon-api contract](../../008-agentic-workflows/contracts/daemon-api.md). Two new
methods, one changed start path, one new refusal. No notification changes: a settings write goes out
as `workflow/changed`, which every window already handles.

## New methods

### `workflows/settings`

```swift
public struct WorkflowSettingsRequest: Codable, Sendable {
    public var folder: URL
    public var workflowID: String
    public var settings: WorkflowSettings
}
// → WorkflowSummary
```

Writes the workflow's file and returns what the page should now show.

The whole of it, in order, and the order is the point:

1. Find the workflow. Not found → `DaemonAPI.Failure.noSuchWorkflow`.
2. Read the file's text. Unreadable → `workflowUnreadable`.
3. Apply each of the three keys through `FrontMatterEdit.set`, one at a time, to the text in hand —
   a value for a key that is set, `nil` for one that is not. A `Refusal` from the editor becomes
   `workflowUnreadable` carrying the editor's own sentence, **and nothing is written** (FR-025).
4. Write atomically.
5. `rescanWorkflows(in:)` — synchronously, not through the debounced watcher. The watcher will fire
   too and find nothing changed; waiting 250ms to tell the window what it just asked for is the kind
   of lag that reads as the app having ignored you.
6. Return `summary(for:)`. The rescan has already broadcast `workflow/changed` to every other window.

The daemon is the writer, not the app, for the reason it is the writer for archiving and running: a
second window — or a phone, later — must not become a second author of the same file.

### `options/remembered`

```swift
public struct RememberedOptionsRequest: Codable, Sendable {
    public var runtimeID: String
    public var cwd: URL
}
// → [ConfigOption]   (empty when nothing is remembered)
```

What `OptionCache` holds for that runtime and folder, and nothing else. **It starts no session and
spawns no process.** This is what fills the menus on the workflow page (FR-023), and the empty answer
is what FR-024 is about: the page then shows the current value and says the choices are not known
yet, rather than offering an empty menu or an invented one.

Keyed with `mcpServers: []`, since a workflow attaches none.

It must not be confused with `agents/options`, which *does* start a session and which returns
remembered options while the real ones are fetched behind it. Reading a workflow should not start a
runtime; deciding whether one may edit your files must not trust a cache. Those are two different
questions and this is the answer to the first one only.

## The changed start path

`DaemonCore+Workflows.startAgent(for:run:prompt:)` today:

```swift
let request = DaemonAPI.StartRequest(
    runtimeID: RuntimeCatalog.builtIn[0].id,
    cwd: workflow.folder,
    prompt: prompt)
let agentID = try await start(request)
```

After:

1. `runtimeID = workflow.settings.runtimeID ?? RuntimeCatalog.builtIn[0].id`.
   `RuntimeCatalog.runtime(id:) == nil` → throw a settings refusal naming the id (FR-009).
2. If `workflow.settings.isEmpty` — **today's path exactly**, and no draft. This is what keeps
   SC-006 true and keeps the common case free.
3. Otherwise: `freshSession(runtimeID:cwd:mcpServers: [])`, register the result as a `Draft`, and
   read `await session.options` — the authoritative list, from `session/new`.
4. `WorkflowSettings.resolve(_:against:)`.
   - `.refused` → end the draft, drop it from `drafts`, and throw a settings refusal carrying
     `refusalDetail`. **No agent is created.** (FR-008, FR-010)
   - `.resolved(let options)` → `start(StartRequest(runtimeID:, cwd:, prompt:, startOptions: options,
     draftID: draftID))`, which reuses that same session. No second process.

`freshSession` becomes internal rather than private. Nothing else about `start` changes, and
`ACPSession.apply` is not touched — see [../research.md](../research.md) §2 for why its leniency is
correct for the person and wrong here.

`fire`'s existing `catch` already turns a thrown error into a recorded refusal. It gains one branch:
a settings refusal is recorded as `.settingRefused`, everything else stays `.unreadable` as today.

## The new refusal

```swift
case settingRefused(setting: String, detail: String)
```

| Aspect | Value | Why |
|---|---|---|
| `message` | `detail` | Written where the refusal is made, because that is where the runtime's name and the offered values are |
| `needsAPerson` | `true` | It refuses every fire until the file changes. The same test `overLimit` and `unreadable` pass |
| `isSameReason(as:)` | compares `setting` only | A weekend of identical refusals is one row with a count, the rule `chainTooDeep` already follows |

`Workflow.refusalIfBlocked` is **not** changed. It is pure and knows nothing about runtimes; a
setting refusal is raised in the start path, where the advertised options are.

## The tool

`AppService.workflowTool`'s description gains a paragraph, after the one about `on:` and `agent:`:

> A workflow may also say how its agent runs: `permission-mode:` (the runtime's own mode, e.g. a
> read-only or plan mode), `runtime:` and `model:`. Leave them out and it runs on the default runtime
> with that runtime's own defaults. Set `permission-mode:` when the person says the workflow must not
> change anything — a workflow runs unattended, so this is the only chance to say so. A mode the
> runtime does not offer stops the workflow running rather than falling back.

Nothing about the tool's schema changes: `content` is already the whole file, so an agent that knows
the keys can write them. `list` and `read` already return the file or `workflow.summary`, so FR-030
falls out of the summary clause with no further change (FR-031: nothing requires an agent to set any
of them).

## Tests

`Tests/AgentsKitTests/Integration/WorkflowSettingsFlowTests.swift`, against `FakeACPAgent` — which
advertises `configOptions` and records every `setConfigOption` it is sent.

| Test | Holds |
|---|---|
| `theModeInTheFileReachesTheRuntime` | FR-006 — assert on the fake's recorded `setOptions` |
| `aModeTheRuntimeDoesNotOfferStartsNoAgent` | **FR-008 — assert the agent count is unchanged and the outcome is `.settingRefused`** |
| `aWorkflowNamingAnUnknownRuntimeIsRefusedNotRehomed` | FR-009 |
| `aWorkflowWithNoSettingsTakesTheOldPath` | FR-002 — no draft is created |
| `writingASettingChangesTheFileAndNothingElse` | FR-020, FR-022, through `workflows/settings` |
| `theWindowHearsAboutItWithoutWaitingForTheWatcher` | `workflow/changed` from the synchronous rescan |
| `aSettingOnAReadOnlyFileIsRefusedAndNotHeld` | FR-025 |
| `fourRefusalsInARowAreOneRowWithACount` | `isSameReason` |
| `rememberedOptionsStartsNothing` | `options/remembered` spawns no process |
