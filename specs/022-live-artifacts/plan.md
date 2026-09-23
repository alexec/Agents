# Implementation Plan: Live Artifacts, A Proof Of Concept

**Branch**: `022-live-artifacts` | **Date**: 2026-09-21, amended the same day for images | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/022-live-artifacts/spec.md`

## Summary

Nearly all of the page exists. The files pane already renders a `.md` file on a paper
surface through `DocumentView` and `MarkdownText`, already watches the agent's folder with
`FolderWatch` and re-reads the open file when anything under it changes, and already opens
whatever file an agent names through `show_file`. What is missing is the *live* half — the
page saying what changed and going there — and the *shared* half — the person typing on it,
and the agent being told.

The plan adds four small things and nothing else:

1. **A passage model.** The document is split into passages — runs of source lines
   separated by blank lines, fences kept whole — each rendered by the existing
   `MarkdownText`. A passage is the unit of everything here: what is marked as changed, what
   the view scrolls to, what the person edits, what is merged, and what the agent is told
   about. Splitting on source lines rather than on the parsed blocks is what makes a passage
   addressable on disk, which Foundation's parser does not give us.
2. **A changed-passage diff.** Old text against new text, by line, mapped to passages.
   Pure, in the kit, tested. The page marks the changed passages and scrolls to the first,
   unless the person is typing.
3. **One sentence of description.** `show_file` is not changed in schema at all; its
   description gains the sentence that a Markdown file opens as a live page that follows
   its edits. A `line` named on a Markdown file now goes to the passage holding it on the
   page, instead of switching the pane to numbered source. No new tool, no new argument.
4. **Writes through the daemon.** A passage the person edited goes to disk by a new
   `artifact/write` request. The daemon writes the file and remembers, per agent, that the
   person changed it and where; on the agent's next turn that memory goes out as a block
   after the person's words, the way the briefing does, and is cleared.

And one thing for pictures, so the agent needs nothing new:

5. **Images are marked when their file changes.** `MarkdownText` already draws a relative
   image, SVG included; the page now remembers each image's modification stamp and, on any
   folder event, re-reads the stamps and marks the passage whose picture changed.

Merging is one function over three strings, line-based, with the person's passage as the
only thing ever moved. A collision keeps the person's text, writes it, and shows the agent's
version in a card. Nothing is stored beyond the daemon's per-agent note, and that note dies
with the daemon by design.

The order is the one the last two features taught: put the surface up and look at it before
building the machinery underneath. Slice A is the read-only live page in the pane, run and
screenshotted; nothing in B–F starts until A is seen to read as a page and to follow.

## Technical Context

**Language/Version**: Swift 6.0, strict concurrency complete; SwiftUI

**Primary Dependencies**: Foundation's CommonMark parser (already, via `MarkdownBlock`);
FSEvents (already, via `FolderWatch`); the app's own MCP server (`AppService`); no
third-party additions

**Storage**: The artifact is the file. The daemon holds one in-memory note per agent — the
passages the person changed since the agent last wrote — not persisted, gone on restart.

**Testing**: swift-testing in `Packages/AgentsKit/Tests/AgentsKitTests`. `Passage`,
`PassageChange`, `PassageMerge`, `ShownFile` and the `show_file` schema are pure and
unit-tested. `artifact/write` and the turn note are tested against `DaemonCore` the way
`show_file` is in `ShowFileTests`. The page itself is walked in the running app, with
screenshots, per [quickstart.md](./quickstart.md).

**Target Platform**: macOS 27, the Mac window only

**Project Type**: Desktop app with a daemon; this touches the app, the kit and the daemon

**Performance Goals**: a change on disk is on the page within 1 s (SC-001) — `FolderWatch`
coalesces at 0.2 s and the file is re-read in full, which is well inside for files up to the
pane's 128 KB prefix; the person's text on disk within 2 s of pausing (SC-003), which is a
1 s debounce plus a round trip to the daemon

**Constraints**: nothing new installed; the daemon stays the only thing that writes on the
person's behalf, so the app never writes a project file itself; no runtime is asked which
runtime it is; the remotes are untouched; `MarkdownBlock` and `MarkdownText` are not changed;
no web view on the page

**Scale/Scope**: one document open per conversation; documents up to 128 KB, a few hundred
passages; a person and one agent editing

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, as 021's plan found. The
gates below are the project's standing rules from the README and the code's own comments.

| Gate | Where it is stated | This feature |
|---|---|---|
| The daemon is the only writer | README, "The daemon" | **Passes.** The app never writes the file: the person's edit goes to the daemon by `artifact/write`, and the daemon writes it inside the agent's `folderScope`, the same check `show_file` makes. |
| Nothing stored outside the root | README | **Passes.** Nothing is stored at all beyond the file the person is editing, which is theirs. |
| One rule, one place | `AgentGroup`, `AgentState` | **Passes.** One tool asks for attention (`show_file`), extended, not duplicated (FR-007). One place splits passages; the page, the diff, the merge and the note all use it. |
| No code asks which runtime it is | README | **Passes.** The turn note goes into `beginTurn` beside the briefing and is worded the same for all. Which runtimes notice a file changed under them mid-turn is a finding, not a branch. |
| A window may be gone and the work goes on | README | **Passes.** The note lives in the daemon, so a person who edits, closes the window, and prompts from the phone still has the agent told. |
| Read-only files pane (004 FR-017) | `FilesPane` doc comment | **Broken, deliberately, for `.md` on the page.** The comment says the terminal is the escape hatch "until a later feature says otherwise". This is that feature, for one file type, and the comment is updated to say so. Listed in Complexity Tracking. |

## Project Structure

### Documentation (this feature)

```text
specs/022-live-artifacts/
├── plan.md              # This file
├── research.md          # Phase 0: the six decisions and what they were checked against
├── data-model.md        # Phase 1: Passage, PassageChange, ArtifactEdit
├── quickstart.md        # Phase 1: how each slice is run and seen to work
├── findings.md          # FR-017: filled in as the slices are walked; the PoC's real output
├── contracts/
│   ├── show-file-tool.md   # The MCP tool: the description changes, the schema does not
│   └── daemon-api.md       # artifact/write, and the turn note's wording
└── tasks.md             # /speckit-tasks output, not made here
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/Model/
└── Passage.swift                # NEW: split, PassageChange (diff), PassageMerge (3-way)

Packages/AgentsKit/Sources/AgentsKitCore/Daemon/
└── DaemonAPI.swift              # + Method.artifactWrite, ArtifactWriteRequest

Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/
├── AppService.swift             # show_file description gains one sentence; schema untouched
└── Briefing.swift               # + artifactEdited(_:) — the turn note's wording

Packages/AgentsKit/Sources/AgentsKit/Daemon/
├── DaemonCore+Artifacts.swift   # NEW: artifactWrite, the per-agent note
└── DaemonCore+Commands.swift    # beginTurn appends the note after the person's words

App/Sources/Sidebar/
├── FilesPane.swift              # opens LivePage for .md, line or no line; FileLines for the rest
├── DocumentView.swift           # becomes the read-only body of LivePage (kept for images etc.)
├── LivePage.swift               # NEW: passages, marks, follow, the editing passage, the card
├── PassageEditor.swift          # NEW: one passage as a TextEditor on the paper
└── ImageStamps.swift            # NEW: which image files the page shows and when they last changed

App/Sources/
└── AppModel.swift               # writeArtifact(_:) → artifact/write

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/PassageTests.swift              # NEW
├── Unit/PassageMergeTests.swift         # NEW
├── Unit/PassageTests.swift              # + passage(containing line:)
├── Unit/AppServiceTests.swift           # + the description sentence; schema asserted unchanged
├── Unit/BriefingTests.swift             # + the note's wording
└── Integration/ArtifactWriteTests.swift # NEW: scope, write, note, cleared on turn
```

**Structure Decision**: Everything pure goes in `AgentsKitCore` beside `MarkdownBlock`, so
both the Mac and, later, a remote can split and merge the same way. The page is Mac-only
and stays in the app target beside the files pane it lives in. No new package, no new
target, no new process.

## Slices

Each slice is run and seen before the next begins. A is the gate: if the page does not read
as a page and follow the agent, the rest is not built on it. E can be built beside C and D;
it shares nothing with them but the passage.

**Slice A — the live page, read-only.** `Passage.split`, `PassageChange`, `LivePage` with
marks and follow. `FilesPane` shows `LivePage` for `.md`, whether or not a line is named. Run the app,
have an agent write a document in steps, screenshot each. *Seen: the page follows and marks.*

**Slice B — attention.** The description sentence; `Passage.index(containing:)`; `LivePage`
taking `openLine` and going to that passage. Then the first measurement: does any runtime call
`show_file` unasked when it starts a document? Recorded in findings; if none does, a
sentence goes in `Briefing` — one sentence, the shortest that works.

**Slice C — typing on the page.** `PassageEditor`, the debounce, `artifact/write`,
`writeArtifact` in the model. The daemon writes; FSEvents brings it back; the page does not
move. *Seen: type, pause, `cat` the file.*

**Slice D — the merge.** `PassageMerge`; the editing passage carried across an external
change; the collision card. *Seen: agent rewrites the section above while the person is
mid-sentence, then the same section.*

**Slice E — pictures.** `ImageStamps` and the mark on a changed image. *Seen: the agent
writes an SVG beside the document and it draws; the agent redraws it and the page marks it
and goes there; a missing image shows its alternative text.*

**Slice F — telling the agent.** The per-agent note in the daemon, `Briefing.artifactEdited`,
appended in `beginTurn`, cleared. *Seen: edit a paragraph, prompt "carry on", the agent's
next write keeps the edit.*

**Slice G — findings.** Every scenario in the quickstart walked with two runtimes;
`findings.md` completed against the checklist of capabilities in it.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| The files pane is no longer wholly read-only | Story 2 is the person typing on the page, and the page is in the files pane | A separate "artifact" pane duplicates the folder watch, the probe and the open-file state for one file type; and the layout is the thing to settle by running, not by adding a tab first |
| A new daemon request rather than the app writing the file | The daemon must know the person edited the file to tell the agent (FR-016), and it is the one thing that already checks folder scope | The app writing and then telling the daemon is two operations that can disagree; the daemon writing is one |
