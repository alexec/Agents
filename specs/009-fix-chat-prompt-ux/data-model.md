# Data Model: Prompt Controls, Project Navigation, Scroll-to-Bottom, Remembered Mode, and Unseen File Requests

**Date**: 2026-09-19 | **Feature**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

Two new value types, one new stored key, four new pieces of view state, and one existing pair
of properties given an explicit joint operation. Nothing persisted by the daemon, no record
shape changed, no migration.

## PromptControlsState

`Packages/AgentsKit/Sources/AgentsKitCore/Model/PromptControlsState.swift`

What the area under the prompt is showing. A total enum, so FR-001 is a compiler obligation
rather than a promise: every way of having no controls is a case, and the view switches over
all of them with no `default`.

| Case | Payload | When | Spec |
|---|---|---|---|
| `.needsFolder` | — | New chat, no `draftCwd` | FR-001, US1-3 |
| `.needsRuntime` | — | New chat, folder chosen, no `draftRuntimeID` | FR-001, US1-3 |
| `.loading` | `runtimeName: String` | A fetch is in flight for the current folder and runtime | FR-001, US1-2 |
| `.failed` | `reason: String` | The last fetch for the current folder and runtime threw | FR-001, FR-004, US1-5 |
| `.nothingOffered` | `runtimeName: String` | A fetch succeeded and the runtime advertised nothing renderable | FR-001, US1-4 |
| `.controls` | `[ConfigOption]` | At least one renderable option | FR-002 |

Derived, never stored. One static function produces it:

```swift
static func resolve(agentOptions: [ConfigOption]?,   // nil when there is no agent yet
                    draftOptions: [ConfigOption],
                    hasFolder: Bool,
                    hasRuntime: Bool,
                    runtimeName: String?,
                    isLoading: Bool,
                    failure: String?) -> PromptControlsState
```

**Rules**, each one a cause from the research:

1. `isLoading` wins over everything except a missing folder or runtime — you cannot be
   fetching for a runtime you have not chosen.
2. Renderability is decided here, with `ConfigOption.isRenderable`, not by the caller. A list
   of unrenderable options is `.nothingOffered`, not `.controls([])`. This is cause 2: the
   empty array must not be able to reach the view as a "row".
3. `agentOptions` non-nil but empty does **not** mean `.nothingOffered` on its own — it means
   fall through to whatever the draft or the failure says. This is the `??` bug (cause 2)
   fixed in the one place that can fix it for both callers.
4. `failure` beats `.nothingOffered`. A fetch that threw told us nothing about what the runtime
   offers.

**Ordering**: `.controls` carries the options already filtered by `isRenderable` and sorted by
`categoryRank`, so the view does no work. That sort is the existing one from `PromptBar:527`.

## ModeMemory

`Packages/AgentsKit/Sources/AgentsKitCore/Model/ModeMemory.swift`

The mode last chosen, per runtime, and the rule for whether it may still be used. Pure; the
`UserDefaults` read and write live in the app.

| Field | Type | Meaning |
|---|---|---|
| `runtimeID` | `String` | Which runtime this was chosen for. Modes do not transfer between runtimes |
| `value` | `JSONValue` | The chosen mode's value, exactly as the runtime's `ConfigChoice` carried it |

Two functions:

```swift
/// The mode option in a list, if the runtime advertises one.
/// By `category == "mode"`, falling back to `id == "mode"`.
static func modeOption(in options: [ConfigOption]) -> ConfigOption?

/// The value to start with: the remembered one if the runtime still offers it,
/// otherwise the runtime's own current value, otherwise nothing.
static func startingValue(remembered: JSONValue?, for option: ConfigOption) -> JSONValue?
```

**Validation rules**

- `startingValue` returns `remembered` only if it appears among `option.options`. A value the
  runtime has stopped offering is discarded (FR-017) and the caller falls back to
  `option.currentValue` (FR-018). No error is raised and nothing is shown to the person.
- A boolean option is never treated as the mode. `modeOption` requires `case .select`.
- Nothing remembered, or no mode option advertised, is not a failure: it is `nil`, and the
  runtime's default stands.

**Identity**: keyed by runtime id alone. Not by folder, not by project — see the spec's
Assumptions, and the checklist note flagging this as the first thing to revisit.

## Stored: the mode preference

| Key | Type | Written | Read | Lifetime |
|---|---|---|---|---|
| `prompt.mode.<runtimeID>` | the mode value, JSON-encoded | Whenever the person changes the mode control, on a draft or on a live agent (FR-019) | When draft options arrive, to seed `draftChosen` (FR-015) | `UserDefaults.standard`, this Mac, survives quitting (FR-016) |

One key per runtime rather than one dictionary, matching `sidebar.isOpen` / `sidebar.width` /
`sidebar.pane`: a runtime that is never used leaves no entry, and a corrupt entry costs one
runtime rather than all of them. Read defensively — a value that will not decode is treated as
nothing remembered.

## View state: the transcript's reading position

Not persisted. This is where you are looking, not what you decided.

| Name | Type | Owner | Meaning |
|---|---|---|---|
| `isAtEnd` | `Bool` | `Transcript` | **Exists today.** Set from `Edges.fromBottom < 160` |
| `canScroll` | `Bool` | `Transcript.Edges` | **Exists today.** Content taller than the pane |
| `hasNewBelow` | `Bool` | `Transcript` | **New.** Set when entries arrive while `!isAtEnd`; cleared the moment `isAtEnd` becomes true (FR-011) |

The jump-to-end button is shown when `canScroll && !isAtEnd` (FR-007, FR-009) and says there is
something new when `hasNewBelow` (FR-011).

## View state: asking for the end

| Name | Type | Owner | Meaning |
|---|---|---|---|
| `scrollToEndToken` | `Int` | `AppModel` | Bumped by `PromptBar.send()` (FR-012) and by the menu command (FR-013). `Transcript` watches it and scrolls |

A counter rather than a `Bool`, so two requests in a row both land. It follows the shape of the
existing `focusedEntry` / `clearFocus` pair, which is how the artifacts pane already asks the
transcript to scroll somewhere.

## Where the window is looking

Not new state — `selectedProject` and `selection` both exist on `AppModel`. What is new is that
moving them together becomes one named operation instead of a side effect of one of them
changing.

| Name | Type | Owner | Meaning |
|---|---|---|---|
| `selectedProject` | `URL?` | `AppModel` | **Exists today.** Which project this window is looking at. Written to `selectedProjectFolder` in `UserDefaults` |
| `selection` | `UUID?` | `AppModel` | **Exists today.** Which conversation is open on top of it. Drives the `NavigationStack` path and `work.watching` |
| `showProject(_:)` | `func` | `AppModel` | **New.** Sets `selectedProject` and clears `selection` **unconditionally**. The rule "picking a project shows the project" in one place, reachable even when the project does not change |

**Invariant**: after `showProject(f)`, `selectedProject == f` and `selection == nil`. It holds
whether or not `f` was already selected — that is the whole bug (FR-021, FR-022).

`selectedProject.didSet` keeps its `guard selectedProject != oldValue` and keeps clearing
`selection`. It is still correct for a programmatic change (`settleProjectSelection`,
`addProject`) and running both is idempotent. Neither path touches an agent (FR-025):
`selection` only decides which transcript this window watches.

## An unseen request to look

Nothing new is stored. `AgentsModel.filesToShow: [UUID: ShownFile]` already exists, is already
keyed by agent, and is already removed by `takeFileToShow` when the conversation is opened. This
feature gives it a second reader rather than a second copy.

| Name | Type | Owner | Meaning |
|---|---|---|---|
| `filesToShow` | `[UUID: ShownFile]` | `AgentsModel` | **Exists today.** A file an agent asked be shown, held until that conversation is opened. Presence is the "unseen" flag |
| `AgentGroup.init(for:wantsEyes:)` | `init` | `AgentsKitCore` | **New overload.** `wantsEyes` sends an otherwise-`running` agent to `.needsAttention`. The existing `init(for:)` stays, as `wantsEyes: false` |

**Invariants**

- The mapping stays total over `(AgentState, Bool)`, so an agent is still in exactly one group
  and never in none. `AgentGroupTests` widens to exhaust both inputs.
- `wantsEyes` never changes `AgentState`. `holdsRuntime`, `hasTurnInFlight` and the transition
  table are untouched, so nothing about queueing or liveness moves (FR-029, FR-030).
- `.archived` and `.stopped` ignore `wantsEyes`: an agent that is not going anywhere is not
  waiting on you.
- The flag does not outlive the window, matching `showFile`'s own "this goes out as an event
  and is gone".

The sidebar dot reads `summary.needsInput || any agent in that folder has an unseen file`. The
first half is the daemon's count, unchanged; the second is this client's own knowledge.

## View state: a change in flight

| Name | Type | Owner | Meaning |
|---|---|---|---|
| `pendingOptions` | `[UUID: [String: Pending]]` | `AppModel` | **New.** The value the person chose, per option per agent, held only while the change is in flight |
| `Pending.value` | `JSONValue` | — | What to show meanwhile |
| `Pending.sequence` | `Int` | — | Which write this was. A completing call clears the entry only if the sequence is still its own (FR-036) |

**Read order** in `PromptBar.binding(for:)`'s getter, for an agent:
`pendingOptions → agent.startOptions.values → option.currentValue`.

**Rules**

- Written synchronously in the setter, before the call starts, so the control changes on the
  same frame the menu closes (FR-032).
- Removed when the call completes, whether it succeeded or threw. The record then decides, so a
  refusal settles on what is really in force rather than on what was asked for (FR-034).
- Never written into `agent.startOptions`. That is the daemon's record mirrored locally, and a
  client that edits it can disagree with the daemon with no way to notice.
- Not persisted, and not carried across a restart. A change in flight when the app quits is
  whatever the runtime settled on.
- The draft path is unchanged: `draftChosen` is already read by the getter, which is why a new
  chat is already immediate (FR-031's equivalent, FR-032 scenario 5).

## View state: the options fetch

| Name | Type | Owner | Meaning |
|---|---|---|---|
| `draftOptionsGeneration` | `Int` | `AppModel` | **New.** Incremented at the start of every `loadDraftOptions`. A reply whose generation is stale is dropped (cause 4) |
| `draftOptionsFailure` | `String?` | `AppModel` | **New.** The last fetch's error, for `.failed`. Distinct from the global `problem` banner, which stays for things that are not about this row |

## The one-click condition

No state. One derived predicate, in `AgentsKitCore` beside the schema it reads, so it is
testable and so the view does not carry the rule:

```swift
/// The single choice this whole form is asking for, if that is all it asks.
public var singleChoice: (property: Property, choices: [Choice])?
```

Non-nil only when the schema has exactly one property and that property is a `.string` with
choices. Everything else keeps the radio group and the Send button (FR-041). `problems(with:)`
is untouched and still gates the Send path.

## Unchanged

`Agent`, `ConfigOption`, `ConfigChoice`, `ConfigChoiceGroup`, `StartOptions`, and every daemon
request and response keep their shape. The three daemon edits guard an assignment; they do not
change what is stored. `Options.swift` gains one lookup helper and nothing else.
