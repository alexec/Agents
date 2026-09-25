# Chat surface contract: the shared views

What each app hands the shared chat views. Nothing in `Shared/UI/Chat` may reach for
`AppModel`, `RemoteModel`, AppKit or UIKit outside `#if os(...)`.

## `ChatActions` (environment value)

| Member | Mac supplies | Phone supplies |
|--------|--------------|----------------|
| `open(ToolCallLocation)` | opens the file in the Mac's editor | sets `fileOnScreen`, which shows the change in a sheet |
| `terminalOutput(String) -> String` | `work.terminalOutput[id]` | the same |
| `unqueue(QueuedPrompt, UUID) async` | `agents/unqueue` | the same |

The default is no-ops, so a preview draws without a model.

## Shared views and their inputs

| View | Inputs |
|------|--------|
| `TranscriptRow(item:isExpanded:toggle:)` | a `TranscriptItem` and its fold state |
| `QueuedPromptRow(prompt:agentID:)` | reads `ChatActions.unqueue` |
| `WorkingLine`, `ComingBackLine` | none |
| `TranscriptScroller` | `settleKey`, `items`, `hasMore`, `loadEarlier`, `entryCount`, `bottomInset`, `scrollToEndToken`, `focusedEntry`, `onHeight`, a `rows` builder and a `foot` builder |
| `JumpToEnd(hasNewBelow:go:)` | as today |
| `PromptHeader(agent:runtimeName:meter:)` | the meter is passed in, because each app computes its cost help text from its own model |
| `CostLimitBanner(kind:spent:raise:goOn:)` | `raise` nil means "say it is changed on the Mac" |
| `OptionsNote(state:retry:)` | a `PromptControlsState` |

## Words

Every user-facing sentence in these views is written once, in these files. The consistency scan
(FR-021) fails if either app's `Chat/` folder repeats one of them as its own literal.
