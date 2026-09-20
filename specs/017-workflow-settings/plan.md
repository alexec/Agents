# Implementation Plan: Workflow Settings

**Branch**: `017-workflow-settings` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/017-workflow-settings/spec.md`

## Summary

Three front-matter keys — `permission-mode:`, `runtime:`, `model:` — a strict resolution of them
against what the runtime actually advertises, a way to write one of them back into a file without
disturbing the rest of it, and a page you reach by clicking a workflow.

The load-bearing line in the whole feature is `ACPSession.apply`:

```swift
public func apply(_ startOptions: StartOptions) async {
    for (id, value) in startOptions.values {
        _ = try? await setOption(id: id, value: value)   // a refusal is noted and passed over
    }
}
```

That is right for a person — they are looking at the control, and an option a runtime dropped should
not cost them an agent. It is exactly wrong for a workflow, because the thing being dropped is the
sentence *this one may not change files* and nobody is in the room. So the workflow start path does
not rely on `apply` at all: it makes the session first, reads what that session really advertises,
resolves the settings against it, and refuses the fire before an agent exists if the answer is not
there. `apply` is untouched, and the person's path with it.

Everything else follows from decisions already made in this codebase. `Workflow.summary` is already
the one renderer read by both the project-page row and the reply an agent gets after writing a
workflow, so adding a clause to it satisfies FR-027 and FR-029 at the same time and cannot drift.
`WorkflowRefusal` is already the type that makes a fire that produced nothing visible, so a setting
that could not be honoured is a new case in it and needs no new surface. `rescanWorkflows` already
turns a changed file into a broadcast, so writing the file *is* the update — the app does not hold a
copy of a setting anywhere, which is what makes "the file is the only source of truth" true rather
than merely intended.

The two genuinely new things are a front-matter editor that changes one key and leaves everything
else alone — comments, ordering, and the keys a later version put there — and a second destination
in the navigation stack, so a workflow is somewhere you go from the project and come back out of, the
way a chat already is.

The phone is untouched: `Remote/` has never drawn a workflow.

## Technical Context

**Language/Version**: Swift 6, strict concurrency.

**Primary Dependencies**: None new. The settings are read by the existing hand-written YAML subset
reader (`YAMLNode`), resolved against `ConfigOption` values the runtime already sends, and applied
through the `StartOptions` field `DaemonAPI.StartRequest` already carries.

**Storage**: The workflow file, and nothing else. No field joins `WorkflowState`, which continues to
hold only what cannot live in a repository — archived, the standing agent, the last outcome. The
option cache (`OptionCache`) is read to populate menus and is never authoritative.

**Testing**: `swift-testing` in `Packages/AgentsKit/Tests/AgentsKitTests`, split `Unit` /
`Integration` / `Live`. The strict-resolution claim is an integration test against `FakeACPAgent`,
which already advertises `configOptions` and already records every `setConfigOption` it is sent —
so "the agent really started in plan mode" and "no agent was started at all" are both assertable
without a runtime, a credential or a network.

**Target Platform**: macOS app plus `agentsd`. No iOS work.

**Project Type**: Desktop app plus a mobile remote over a local daemon.

**Performance Goals**: The workflow start path gains no process. A workflow with settings makes its
session through the same `freshSession` the start would have made anyway, registers it as a draft,
and hands the draft id to `start` — one runtime, as today. A workflow with no settings skips that
entirely and takes exactly today's path.

**Constraints**:

- A permission mode that is not on offer must never fall back (FR-008). Every fallback is more
  permissive than what was asked for.
- No file already on disk may change meaning (FR-002, SC-006).
- Writing a setting must not reformat the file (FR-022). This is the requirement that decides the
  editor is textual rather than a YAML round-trip.
- Every workflow must be clickable, including one whose front matter cannot be parsed (FR-013,
  FR-016) — which is the one most likely to need looking at.
- Settings apply at start only, and a `triggering` workflow starts nothing (FR-011). The row must
  not claim a mode that will never be applied.
- The daemon owns the write, so a window that is not this machine's cannot become a second writer.

**Scale/Scope**: Two new source files in `AgentsKitCore`, one new view in the app, six files edited,
three new test suites. Around 450 lines of source.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unedited template — every principle is a
`[PRINCIPLE_N_NAME]` placeholder — so there are no ratified gates and none are invented here. In
their place, the conventions this codebase holds itself to, read off its sources, and how this
design stands against each:

| Standing convention | How this design stands |
|---|---|
| No code asks which runtime it is talking to (README; `RuntimeDiscovery`) | The permission mode's values are the runtime's own, passed through as written. Nothing translates `plan` between runtimes and nothing keeps a list of modes. The option is found the way `ModeMemory` already finds it — by `category`, not by runtime. |
| A decision that can be wrong in a way a person would notice is pure and unit-tested (`ModeMemory`, `Workflow.refusalIfBlocked`) | `WorkflowSettings.resolve` and `FrontMatterEdit.set` are both pure functions of their inputs. Neither does I/O, and both are table-tested. |
| Every fire leaves a mark (008, FR-026) | A setting that cannot be honoured is a `WorkflowRefusal` case like every other, shown on the row with the same words in the same place. |
| One renderer, so the page and the agent cannot describe the same thing differently (`Workflow.summary`) | The settings clause goes into `summary`, which both already read. No second renderer is added. |
| What the app knows and what the repository knows are kept apart (`WorkflowState`) | Settings are in the file. Nothing about them is written to `WorkflowRecords`, and the app holds no copy to fall out of step. |
| A file from a later version is listed and inert, never rejected (`WorkflowTrigger.unrecognised`, `Workflow.unknownFields`) | An unrecognised setting key stays in `unknownFields` and survives being written back. A *known* key with a value the runtime does not offer is a refusal, not a parse failure — the file is fine, the world moved. |
| Comments say why, at length, and name what would go wrong otherwise | The `apply` asymmetry is the thing a later reader will want to undo. It is written into `DaemonCore+Workflows`, not only into this plan. |

**Post-design re-check**: passes unchanged. One point deserves naming rather than hiding: this
feature makes the project page write to a file in the person's repository for the first time. That
is FR-020, it was asked for explicitly, and it is bounded — one key at a time, in the front matter,
in the workflow folder, by the daemon, never touching the body. The editor refuses anything it
cannot do safely rather than doing its best.

## Project Structure

### Documentation (this feature)

```text
specs/017-workflow-settings/
├── plan.md                      # This file
├── research.md                  # Phase 0: the six decisions, including why apply() is left alone
├── data-model.md                # Phase 1: WorkflowSettings, the new refusal, what did not change
├── quickstart.md                # Phase 1: how to see it work, fake and by hand
├── contracts/
│   ├── workflow-settings.md     # The type, the resolver, the summary clause
│   ├── front-matter-edit.md     # The in-place editor and what it refuses
│   ├── daemon-api.md            # Two new methods, one new refusal, one changed start path
│   └── workflow-page.md         # What clicking a workflow opens, and the navigation it needs
├── checklists/
│   └── requirements.md          # From /speckit-specify
└── tasks.md                     # Not created by /speckit-plan
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/
│   ├── WorkflowSettings.swift       # NEW. The three settings, the resolver, the refusal words
│   ├── Workflow.swift               # `settings` field; `summary` gains its clause
│   ├── WorkflowOutcome.swift        # WorkflowRefusal.settingRefused
│   └── FrontMatter.swift            # FrontMatterEdit joins it: strip reads, set writes
└── Daemon/DaemonAPI.swift           # workflows/settings, options/remembered, their payloads

Packages/AgentsKit/Sources/AgentsKit/
├── Workflows/WorkflowFile.swift     # parses the three keys; they leave `unknownFields`
└── Daemon/
    ├── DaemonCore+Workflows.swift   # strict start path; setWorkflowSettings
    ├── DaemonCore+Commands.swift    # freshSession becomes internal; rememberedOptions method
    ├── DaemonCore+Dispatch.swift    # the two new methods routed
    └── ACP/Serve/AppService.swift   # the tool description says the settings exist

App/Sources/
├── ContentView.swift                # the stack's path becomes Page, of at most one
├── AppModel.swift                   # openWorkflow; setWorkflowSettings; rememberedOptions
└── Projects/
    ├── WorkflowRow.swift            # the row opens the workflow
    └── WorkflowPage.swift           # NEW. The workflow, whole, with its settings changeable

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/
│   ├── WorkflowSettingsTests.swift  # NEW. parsing, resolving, the summary clause
│   ├── FrontMatterEditTests.swift   # NEW. set, replace, remove, and everything left alone
│   └── WorkflowFileTests.swift      # the three keys, and an unknown one still kept
└── Integration/
    └── WorkflowSettingsFlowTests.swift
                                     # NEW. the mode reaches the runtime; a mode that is not
                                     #   offered starts no agent; the file changes and the
                                     #   project page hears about it
```

**Structure Decision**: `WorkflowSettings` goes in `AgentsKitCore`, beside `Workflow`, because it is
part of what a `WorkflowSummary` carries to a window and the module line is drawn at what a window
needs to draw. `FrontMatterEdit` goes beside `FrontMatter` for the reason that file gives for
existing at all: the positional rule about `---` is stated once, and a second implementation of it
is how the top of somebody's document gets eaten.

The editor is in Core rather than in the daemon because it is a pure function of text and because
that is where `swift test` can reach it without a daemon. The *writing* — the file handle, the
atomic replace, the rescan — stays in `DaemonCore+Workflows` with every other workflow write.

## Complexity Tracking

No Constitution Check violations. Two decisions are worth recording as deliberate rather than as
complexity:

| Decision | Why | Simpler alternative rejected because |
|---|---|---|
| The workflow start path makes its own session and validates before `start` | FR-008 needs the answer before an agent exists. `start` creates and saves the agent, then applies options — refusing after that leaves a record of an agent nobody wanted. | Making `apply` strict changes the person's path too, where leniency is correct and tested. Checking against `OptionCache` instead would be checking against a remembered answer, and a stale cache saying "plan is available" is the exact failure this is here to prevent. |
| A textual front-matter editor rather than parse-and-re-serialise | FR-022. `YAMLNode` reads a deliberate subset and has no writer; giving it one means deciding how to re-emit every file anyone has written, including comments it never modelled. | Re-serialising is fewer lines and silently rewrites the author's file. The one thing a person notices immediately about a tool that edits their repository is that it moved something they did not ask it to move. |
