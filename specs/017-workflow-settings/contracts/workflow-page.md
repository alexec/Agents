# Contract: The workflow page

**Module**: app · **File**: `App/Sources/Projects/WorkflowPage.swift` (new)

What clicking a workflow opens. The third thing the reader asked for, and the one that makes the
other two usable: *I always want the user to be able to click on the workflow and view the workflow.*

## Getting there

`ContentView` already says what a destination is in this app:

> A chat is somewhere you go from the project and come back out of, rather than a column sitting
> beside it, so it is a push and the back button is the way home.

A workflow is the same kind of thing, so it is the same kind of push. The stack's path becomes a
`Page` of at most one:

```swift
enum Page: Hashable {
    case agent(UUID)
    case workflow(String)      // Workflow.id — folder path + "/" + workflowID
}
```

```swift
private var page: Binding<[Page]> {
    Binding(get: {
        if let id = model.openWorkflow { return [.workflow(id)] }
        return model.selection.map { [.agent($0)] } ?? []
    }, set: { pages in
        switch pages.last {
        case .agent(let id):     model.selection = id;   model.openWorkflow = nil
        case .workflow(let id):  model.openWorkflow = id; model.selection = nil
        case nil:                model.selection = nil;   model.openWorkflow = nil
        }
    })
}
```

`model.selection: UUID?` is **not** widened into an enum. Its `didSet` sets `work.watching` and
reloads the transcript, and it is threaded through the view tree as a binding in some forty places; a
sibling `openWorkflow: Workflow.ID?` costs one field and leaves every one of those call sites alone.
The two are exclusive, which the setter enforces in the only place that sets them from navigation.

`selectedProject.didSet` and `showProject(_:)` clear `openWorkflow` alongside `selection`, for the
reason already written there: picking a project shows the project.

## The row

`WorkflowRow` gains a click over the whole card that sets `model.openWorkflow`. Three things on it
must keep their own hit area and their own meaning:

| Already there | Still does |
|---|---|
| The play button | Runs it now |
| The archive button | Archives it |
| The *Ran →* link | Goes to the agent that run started |

The context menu keeps *Run now*, *Archive* / *Restore* and *Show in Finder*, and gains nothing:
opening is what the row now does by itself.

## What the page shows

Top to bottom, in the project page's 144pt gutter so it reads as the same document:

1. **Name.** The file's `name:`, or the file name made readable, as the row shows it.
2. **What it is.** `workflow.summary` — the trigger in plain words, which agent runs it, and the
   settings clause. The same sentence as the row, deliberately: the page is the row opened up, not a
   second description of the same thing.
3. **When it next runs**, and **what happened last** — including a refusal with its count, and a
   link to the agent a run started. Everything the row's third line carries (FR-019).
4. **Settings.** Three controls: permission mode, runtime, model. See below.
5. **The prompt**, in full, selectable, in a monospaced block, exactly as it will be sent. This is
   FR-015 and it is the reason the page exists: an agent can write a workflow in this app without
   anybody's approval, and until now the prompt was the one part of it nobody could see.
6. **Where the file is**, with *Show in Finder*.
7. **Run now** and **Archive** / **Restore**, as words rather than icons — there is one of each on
   this page, so the reason the row uses icons does not apply.

## Guarantees

| # | Guarantee | Requirement |
|---|---|---|
| P1 | Every workflow opens: archived, over a ceiling, unsupported, unreadable | **FR-013, SC-002** |
| P2 | An unreadable workflow shows its problem *and* the file's raw text | FR-016 |
| P3 | The page follows the file — a change on disk redraws it, via `workflow/changed` | FR-017 |
| P4 | A workflow whose file is deleted while open returns the reader to the project page, saying so | FR-017, edge case |
| P5 | The prompt is shown whole and unedited, and is not editable here | FR-015, FR-021 |
| P6 | Triggers and the prompt body have no control on this page | FR-021 |
| P7 | An archived workflow says it will not run, and offers Restore | FR-013 |
| P8 | Back returns to the project page | — |

## The settings controls

Each is a menu, built from `options/remembered` for the workflow's runtime and this project — the
same `OptionMenu` the prompt bar draws, so a mode picker looks like a mode picker wherever it is.

| State | What is drawn | Requirement |
|---|---|---|
| Choices remembered, value among them | An ordinary menu, the value selected | FR-023 |
| Choices remembered, value **not** among them | The value shown, marked as one this runtime does not offer, with what it does offer — this workflow is currently refusing every fire, and this page is where that is explained | FR-008, FR-024 |
| Nothing remembered for this runtime and folder | The current value, and a line saying the choices are not known until this runtime has been used here. Never an empty menu, never an invented one | **FR-024** |
| Runtime not in the catalog | The value shown, marked unavailable | FR-009 |

Changing one calls `workflows/settings`. The daemon writes the file and answers with the summary; a
refusal from the editor becomes the app's ordinary *That did not work* alert with the editor's own
sentence, and the control snaps back to what the file still says (FR-025).

**When the mode is `triggering`**, the three controls are shown and disabled, under one line: *this
workflow resumes the agent that triggered it, so these do not apply.* Shown rather than hidden,
because a person changing `agent:` in the file needs to find them again — and because a hidden
control is not an explanation. This is FR-011's other half; the row's half is that
`workflow.summary` omits the clause entirely for this mode.

**When the mode is `standing`**, one line: *applied when its standing agent is started, and again if
it has to be replaced.*

## Tests

The app has no view tests. What is testable is held below the view and is:

- `Workflow.summary` for each mode — [workflow-settings.md](./workflow-settings.md).
- `WorkflowSettings.resolve` against remembered options, including the not-offered case the page has
  to draw — same contract.
- `workflows/settings` end to end — [daemon-api.md](./daemon-api.md).

P1 through P8 are checked by hand, once, following [../quickstart.md](../quickstart.md).
