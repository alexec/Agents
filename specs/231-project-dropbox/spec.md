# Feature Specification: A drop box per project

**Feature Branch**: `agents/build-free-spec-work`

**Created**: 2026-10-04

**Status**: Draft

**Input**: Issue #231, "Drop box per project: files dropped in .agents/dropbox trigger workflows". Alex's decisions of 2026-10-04 in the issue are taken as given. The issue's two open points, upload on the Remote and the web page and a subfolder from a Mac drag, are answered here with a default. They are repeated, with a few more found while grounding the spec in the code, under [Open questions](#open-questions-for-alex).

## Why this feature exists

Alex wants one place to hand work to agents. Save or drag a file into a project's drop box, from Finder, a script, the phone or the web page, and a workflow in that project picks it up. The drop box is just a folder, `<project>/.agents/dropbox/`. A file arriving there raises the event `dropbox.file_added`, and a workflow triggers on it like any other event.

How the code stands today (`PK` = `Packages/AgentsKit/Sources/AgentsKit`, `PKC` = `Packages/AgentsKit/Sources/AgentsKitCore`):

- **Each project is already watched**, once (#173, `PK/Daemon/DaemonCore+Workflows.swift:98` `watchProject`).
  - The watch leaves out `.agents/worktrees`, `.git/objects` and build output (:124–146).
  - It feeds pins, branches, the workflow rescan, the dashboard and `project.json` (:159).
  - On the Mac, FSEvents reports **folders, not files** (`PK/Files/FolderWatch.swift:79`), coalesced over 0.2 s. On Linux servers, inotify does the same (`FolderWatch+Linux.swift`). Its mask includes "closed after writing", but the flag is thrown away (:120).
  - So a drop-box hook goes beside the others, and finds new files by listing the folder and comparing with what it saw last.
- **Events have one funnel**, `raise` (`PK/Daemon/DaemonCore+Events.swift:17`). It logs, persists, broadcasts, wakes waits and fires workflows. Details are text key-value pairs.
  - The log keeps 7 days and at most 10,000 events (`PKC/Model/EventLog.swift:19`).
  - Identical events within 60 s fold into one row, but each still fires workflows.
  - Subjects are a closed list (`PKC/Model/EventCatalogue.swift:4`), so `dropbox` is a new one.
  - #195's `mac.disk_low` (b907f0cb) is the latest template for a new event across catalogue, docs, web model and protocol. Its "once per crossing" memory lives in `EventState` (`PK/Store/EventStore.swift:198`).
- **Triggers match exactly** (`PKC/Model/DetailFilter.swift:33`). A filter value is one value or a list ("any of", #99/073), compared as exact text, except for `labels`. So the daemon must put `folder` and `extension` into one fixed form, for the filter to mean what a person expects.
- **A project event reaches only that project's workflows** (`fireWorkflows`, `DaemonCore+Events.swift:113`).
  - A `new` or `standing` run is told the event and its details at the end of its prompt (`DaemonCore+Workflows.swift:871`).
  - `agent: triggering` needs an agent behind the event, so it can't run on a drop-box event.
- **One run in flight per workflow.** A second fire is refused as `run_in_flight`. With `cooldown:` it is held, but only the last held trigger is kept (`PKC/Model/WorkflowOutcome.swift:274,308`, `DaemonCore+Workflows.swift:1085`). Five files dropped together would therefore give **one** run today, and four refusals. That is the biggest gap this spec closes.
- **Uploading.**
  - The only file-writing call today is `files/write` (`PKC/Daemon/DaemonAPI.swift:312`). It belongs to an agent, writes into `<cwd>/.agents/attachments/`, and allows at most 25 MB, sent in one piece.
  - The Remote and the web page attach files to a prompt by value, at most 900 KB a prompt, to fit the relay's 1 MB record (`PKC/Model/PhoneAttachment.swift:22`, `Web/src/model/attachments.ts:11`).
  - Neither has an upload to a project.
- **Mac drops.**
  - The whole project list takes dropped folders, which become projects (`App/Sources/Projects/ProjectListView.swift:139`).
  - The prompt bar takes dropped files as attachments (`App/Sources/Chat/PromptBar.swift:529`).
  - Project rows (`ProjectRow.swift`) and session rows (`AgentRow.swift`) take nothing.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A file saved into the drop box runs a workflow (Priority: P1)

Alex writes this workflow in a project:

```markdown
---
name: Review what lands in the drop box
on:
  - dropbox.file_added:
      folder: review
      extension: [pdf, md]
agent: new
---

Read the dropped file and review it. Move it to dropbox/done/ when finished.
```

Then Alex saves `proposal.pdf` from Preview into `<project>/.agents/dropbox/review/`. A new agent starts. Its prompt ends with the event, including the file's full path, and it reviews the file and moves it to `dropbox/done/`.

**Why this priority**: This is the feature. Every other story is a way of getting a file into the folder.

**Independent Test**:
- On a scratch root, write the workflow above.
- Copy a PDF into `dropbox/review/`, a PDF into `dropbox/notes/`, and a `.txt` into `dropbox/review/`.
- Exactly one run starts, for the first file. Its prompt carries the path, name, folder, extension and size.
- The Events page shows three `dropbox.file_added` rows.

**Acceptance Scenarios**:

1. **Given** the workflow above, **when** a PDF arrives in `dropbox/review/`, **then** one `dropbox.file_added` event is raised and the workflow runs once. Its agent's prompt ends with the event's sentence and details.
2. **Given** the same workflow, **when** a PDF arrives in `dropbox/notes/` or at the top of `dropbox/`, **then** the event is raised, and this workflow does not run.
3. **Given** the same workflow, **when** `PROPOSAL.PDF` arrives in `dropbox/review/`, **then** it runs, because `extension` is lower-case without the dot (FR-004).
4. **Given** a workflow with `agent: triggering` on `dropbox.file_added`, **then** its page says that a drop-box event has no agent behind it, as it does for any such event today. It never runs.
5. **Given** a workflow in another project, **then** it never hears this project's drop-box events.
6. **Given** a workflow's agent moves the file to `dropbox/done/`, **then** that move raises `dropbox.file_added` for `folder: done` (FR-009). A workflow listening on every folder would hear it. The how-to says to narrow by `folder:` for this reason.

---

### User Story 2 - Several files at once each get their run (Priority: P1)

Alex drags five invoices into `dropbox/invoices/` at once. The invoice workflow handles all five, one run after another, none of them dropped.

**Why this priority**: Without this, today's one-run-in-flight rule refuses four of the five. The feature would look broken the first time anyone drops more than one file.

**Independent Test**:
- With a `new` workflow on `folder: invoices`, copy five files in one go.
- Five `dropbox.file_added` events are raised.
- Five runs start one after another, each told a different file.
- None is refused as `run_in_flight`.

**Acceptance Scenarios**:

1. **Given** a workflow with a run in flight, **when** another drop-box event matches it, **then** that event is **queued** for the workflow, not refused and not collapsed into one held trigger (FR-012).
2. **Given** queued events, **when** the run in flight ends, **then** the next queued event runs, oldest first, subject to the workflow's cooldown and the day spending limit as today.
3. **Given** a queued file has been moved or deleted before its turn, **then** its entry is dropped from the queue, and the Events page shows `workflow.refused` with reason `file_gone`.
4. **Given** the daemon restarts with events queued, **then** the queue survives, and each queued file still in the folder runs (FR-013).
5. **Given** `agent: standing`, **then** queued events go to the standing agent one at a time, each as its own prompt.

---

### User Story 3 - Drag a file onto a project on the Mac (Priority: P1)

Alex drags `notes.md` from Finder onto a project's row in the sidebar. It is copied into that project's `dropbox/`. Dragging it onto a session's row does the same for that session's project, never the session's worktree.

**Why this priority**: This is the Mac's everyday way in, and the issue's decision.

**Independent Test**:
- Drag a file onto a project row, onto a session row whose session is in a worktree, and onto the list's empty background.
- The first two land in `<project>/.agents/dropbox/`. Neither lands in the worktree.
- The background drop of a file is refused, and a folder dropped on the background still adds a project.

**Acceptance Scenarios**:

1. **Given** a file dragged over a project row, **then** the row shows it will take the drop, and dropping copies the file into `<project>/.agents/dropbox/`. The original is left in place.
2. **Given** a file dragged onto a session row, **then** it goes to the session's project's `dropbox/`, even when the session works in a worktree.
3. **Given** a folder dragged onto the list's background, **then** it is added as a project, as today. **Given** a file dragged onto the background, **then** nothing happens.
4. **Given** a folder dragged onto a project row, **then** it is copied into `dropbox/` as a subfolder, and each file inside raises its own event (Edge Cases).
5. **Given** a file is already in `dropbox/` under the same name, **then** the drop replaces it and raises the event again.
6. **Given** a server project's row, **then** the drop uploads the file to that server's project (FR-015). The row shows progress for a large file.
7. **Given** a file dropped on the prompt bar, **then** it is still attached to the message, as today.

---

### User Story 4 - Choose a subfolder (Priority: P2)

Alex has `dropbox/review/` and `dropbox/notes/`, each with its own workflow. On the Mac, Alex right-clicks a project row and chooses **Add to Drop Box ▸ review…**, or drops the file onto `review` in the Files pane. On the phone and the web page, the upload asks which folder.

**Why this priority**: Subfolders are how workflows split the drop box (Alex's decision). But the top folder works without them.

**Independent Test**: From each client, put one file into `dropbox/review/` and one at the top. Check where each landed and which workflow ran.

**Acceptance Scenarios**:

1. **Given** a project row's context menu on the Mac, **then** **Add to Drop Box** lists the top folder, then each existing subfolder one level down, then **New Folder…**. Each opens a file chooser.
2. **Given** the Files pane showing the project's `.agents/dropbox/` folder or a subfolder of it, **when** a file is dropped onto a folder there, **then** it is copied into that folder.
3. **Given** a plain drag onto a row, **then** it always goes to the top of `dropbox/`. There is no hover menu (see Open questions, Q2).
4. **Given** an upload from the Remote or the web page, **then** a folder field offers the top folder, each existing subfolder, and a new name.

---

### User Story 5 - Upload from the phone and the web page (Priority: P2)

On the iPhone, Alex opens a project, taps **Add to Drop Box**, picks a PDF from Files and the folder `review`, and taps Add. The Mac's workflow runs. On the web page, Alex drags a file onto the project page's drop-box area, or uses its **Add files** button.

**Why this priority**: The #233 rule needs all three clients, and Alex's decision is "upload from every app". It is P2 because the folder already works from Finder and scripts without it.

**Independent Test**:
- From the Remote, by the relay and on the local network, upload a 50 KB file and a 20 MB file into a Mac project's `dropbox/review/`.
- Do the same from the web page in Chrome and Safari, and into a server project.
- Each file arrives whole, with one event. A cut-off upload leaves nothing in `dropbox/`.

**Acceptance Scenarios**:

1. **Given** the Remote's project page, **then** **Add to Drop Box** offers Files (any file), Photos, and paste. A folder field, a progress bar and a Cancel button follow.
2. **Given** the web page's project page, **then** a **Drop box** section takes files dragged onto it and has an **Add files** button (a file input taking several files), with the same folder field and progress.
3. **Given** a file larger than one relay record, **then** it is sent in pieces and put together on the host (FR-016). It appears in `dropbox/` only when complete, so the watcher sees one finished file.
4. **Given** an upload is cut off (the connection drops, the person cancels, the app is closed), **then** nothing appears in `dropbox/`. The pieces already sent are removed within an hour (FR-017).
5. **Given** a name already in the folder, **then** the upload replaces it and the event fires again, as on the Mac.
6. **Given** the Remote's share sheet, **then** "Add to Drop Box" from another app is **not** in this spec (Open questions, Q4).

---

### User Story 6 - See what is waiting in the drop box (Priority: P3)

On the project page, on all three clients, Alex sees a **Drop box** line: how many files are in it and how much they weigh, which workflows listen to it, and the newest few files. It opens the folder in the Files pane on the Mac.

**Why this priority**: Since the daemon never deletes a dropped file, the only bound on the folder is the person seeing it grow. It is P3 because the event and upload work without it.

**Acceptance Scenarios**:

1. **Given** a project with files in `dropbox/`, **then** its page shows the count, total size, the newest five files with their folders, and the workflows whose triggers name `dropbox.file_added`.
2. **Given** files in a subfolder no workflow listens to, **then** the line says so, for example "3 files in `notes/`, no workflow listens".
3. **Given** the drop box passes its warning line (FR-020), **then** the project page and the sidebar row show a warning, and `dropbox.full` is raised once per crossing.

### Edge Cases

- **Files already there at startup**: they raise nothing (Alex's decision). The daemon takes a first listing when it starts watching a project. Only files that appear or change after it fire. Files that arrived while the daemon was down are therefore not announced (Open questions, Q5).
- **A file still being written** (a download in progress, a slow copy, `cp` of a large file): it fires once, after it has finished.
  - "Finished" means its size and modification time are unchanged across two looks a second apart.
  - On Linux it also means a "closed after writing" notice was seen.
  - An upload through the app is written aside and moved in whole, so it is finished when it appears.
- **Browser and Finder part-files** (`.crdownload`, `.download`, `.part`, `.partial`): these are files still being written. They are renamed when done, and the renamed file fires. They never fire under their part name, however long they stay still.
- **Finder's own housekeeping** (`.DS_Store`, `._*` AppleDouble files, `Icon\r`): not arrivals, and never fire. These are system files, not an ignore list for the person (Open questions, Q6).
- **Same name again**: a file replaced under the same name fires again, once it is finished. A copy of the very same bytes fires again too, because the person dropped it again: the daemon compares the file's identity on disk (a new file or a new modification time), not its content.
- **A file moved within `dropbox/`** (`review/` to `done/`): it fires for its new folder (User Story 1, scenario 6). Leaving it from `dropbox/` raises nothing.
- **A folder dropped into `dropbox/`**: the folder itself raises nothing, and each file inside, at any depth, raises its own event. `folder` is the path relative to `dropbox/`, for example `review/2026`.
- **A symlink in `dropbox/`**: raises an event with the link's path. The daemon never follows it into another folder to look for more files.
- **Deep or huge trees**: no limit (Alex's decision). The daemon's listing work is bounded by what is in the folder, and the watch already recurses.
- **A project on a server**: the server's daemon watches its own project's drop box. Uploads from the Mac, the phone and the web page go to that host.
- **Worktrees**: a worktree has its own `.agents/dropbox/` checked out if the project commits one, but only the project's main folder is watched. Files dropped into a worktree's copy raise nothing.
- **Git**: `dropbox/` is not ignored by the app. A project that doesn't want dropped files committed adds its own `.gitignore` line. The how-to says so.
- **The workflow's own agent writes into `dropbox/`**: it fires as any file does. The daemon can't tell who wrote a file, so it can't skip a workflow's own writes, and the chain-depth limit doesn't apply to an event with no agent behind it. The how-to warns against a workflow writing into the folder it listens on, and the queue (FR-012) keeps a loop to one run at a time.
- **A drop-box event while the workflow is off, archived or awaiting approval**: refused as today, with today's reasons. It is not queued.
- **A queue for a workflow that is then switched off or deleted**: its queued events are dropped, each with a `workflow.refused` row.
- **The 60-second fold on the Events page**: two drops of the same name in a minute fold into one row with a count, and each still fires (as today, `EventLog.swift:32`).

## Requirements *(mandatory)*

### Functional Requirements

**The folder and the event**

- **FR-001**: Each project's drop box MUST be `<project folder>/.agents/dropbox/`. The app MUST create it when it lays out a project's `.agents/` folder, and MUST NOT add it to any ignore file.
- **FR-002**: The daemon MUST raise `dropbox.file_added`, scoped to the project, once for each file that appears in the drop box or in any subfolder of it, or is replaced there, after the daemon began watching the project.
- **FR-003**: The event MUST carry these details:
  - `path`: the file's absolute path on its host.
  - `name`: the file name.
  - `folder`: the subfolder path relative to `dropbox/`, with `/` between levels and no leading or trailing `/`. It is empty at the top.
  - `extension`: the extension, lower-case, without the dot, empty when there is none.
  - `size`: in bytes.
  
  Its sentence MUST read, for example, *proposal.pdf (1.2 MB) arrived in the drop box, in review/*.
- **FR-004**: `extension` filter values MUST be matched case-insensitively and with or without a leading dot. `folder` values MUST be matched without leading or trailing `/`. All other details match exactly, as today.
- **FR-005**: `dropbox` MUST be a new event subject, with its own glyph and group on the Events page and in the workflow page's trigger words. `dropbox.*` MUST match its events.
- **FR-006**: A file MUST NOT fire while it is still being written (Edge Cases). It MUST fire exactly once when it is finished.
- **FR-007**: Files present when the daemon starts watching a project MUST NOT fire.
- **FR-008**: Finder's housekeeping files and part-files MUST NOT fire (Edge Cases). Nothing else may be left out: no size or rate cap, no `.gitignore` rules.
- **FR-009**: The daemon MUST NOT move, rename or delete a file in the drop box, except to finish an upload it is writing (FR-016).
- **FR-010**: The daemon's memory of what it has seen MUST be bounded by what is in the folder now. Files that leave are forgotten.

**Workflows**

- **FR-011**: A workflow MUST be able to trigger on `dropbox.file_added`, narrowed by any of its details. A `new` or `standing` run MUST be told the event and its details, as for any event without an agent behind it.
- **FR-012**: A workflow's matching drop-box events MUST be queued while a run of it is in flight, or while its cooldown holds, and run one at a time, oldest first. Other events keep today's in-flight and cooldown behaviour.
- **FR-013**: The queue MUST persist across daemon restarts. An entry MUST be dropped, with `workflow.refused` reason `file_gone`, when its file is no longer at its path when its turn comes.
- **FR-014**: A workflow's queue MUST be shown on its page, on all three clients, as the number waiting and the next file.

**Upload**

- **FR-015**: The daemon MUST offer an upload into a project's drop box, scoped to a project on a host (not to an agent), with an optional subfolder. All three clients MUST use it, the Mac's server projects included. For a project on this Mac, the Mac window MAY copy the file directly instead.
- **FR-016**: An upload MUST be sendable in pieces that each fit one relay record. It MUST be written outside the drop box, and moved in whole only when every piece has arrived. It has no total size limit (Alex's decision).
- **FR-017**: An upload not finished within an hour of its last piece, or cancelled, MUST be removed by the daemon. Upload pieces MUST never be kept beyond that.
- **FR-018**: An upload's name MUST be cut to its last path component, and its subfolder MUST stay inside the drop box: no `..`, no absolute path, and no path through a symlink out of it. Anything else is refused with a sentence.
- **FR-019**: Every client a person has paired MAY upload, under the one grant (#111). There is no separate drop-box permission.

**Seeing it**

- **FR-020**: Each project page, on all three clients, MUST show the drop box's file count and total size, its newest five files, and which workflows listen (User Story 6). Past a warning line (Open questions, Q3), the app MUST warn on the project page and raise `dropbox.full` once per crossing, as `mac.disk_low` does. It MUST NOT refuse files or delete them.

**Mac**

- **FR-021**: Project rows and session rows MUST accept dropped files and folders, and copy them to the project's main `dropbox/` (User Story 3). The list's background MUST still add a dropped folder as a project, and MUST do nothing with a dropped file.
- **FR-022**: A project row's context menu MUST offer **Add to Drop Box** with the subfolders (User Story 4). The Files pane MUST accept drops onto folders under `.agents/dropbox/`.

**Compatibility**

- **FR-023**: A client that doesn't know `dropbox.file_added` MUST still show the event on its Events page as an unknown event, and MUST still show a workflow triggered by it, as it does any trigger it doesn't fully understand.
- **FR-024**: An older host MUST refuse an upload call it doesn't know, and the newer client MUST say the host needs updating.

### Key Entities

- **Drop box**: `<project>/.agents/dropbox/` and its subfolders, on the project's host.
- **Arrival**: a finished file that appeared or was replaced in the drop box. It raises one event.
- **Seen list**: per project, the files in the drop box the daemon has already announced, with their identity on disk. It is bounded by the folder's contents.
- **Workflow queue**: per workflow, drop-box events waiting for a run in flight to end. It is persisted, and pruned of files that are gone.
- **Upload**: an in-progress transfer into a drop box. Pieces sit outside the drop box until whole, and are removed after an hour unfinished.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For 100 files copied into the drop box in one go, exactly 100 events are raised, and a matching `new` workflow runs 100 times, one after another, with no `run_in_flight` refusals.
- **SC-002**: For a 2 GB file copied slowly into the drop box, exactly one event is raised, after the copy ends.
- **SC-003**: Restarting the daemon with 50 files already in the drop box raises no events.
- **SC-004**: From the Remote and the web page, a 100 MB file uploaded by the relay arrives whole with one event. A cut-off upload leaves nothing in the drop box and nothing on disk after an hour.
- **SC-005**: A file dropped on a project or session row on the Mac arrives in the project's main drop box in under two seconds for a 10 MB file, and never in a worktree.
- **SC-006**: Every project page, on all three clients, shows how much is waiting in the drop box. No drop box grows without the person being able to see it.

## Docs *(mandatory)*

- `docs/reference/events.md` — change: a **Drop box** section with `dropbox.file_added` (path, name, folder, extension, size) and `dropbox.full`. Say that `extension` and `folder` match loosely (FR-004).
- `docs/reference/workflows.md` — change:
  - the `on:` example with `folder:` and `extension:`
  - drop-box events queue rather than being refused (FR-012)
  - `agent: triggering` can't run on them
- `docs/how-to/hand-files-to-a-workflow.md` — new:
  - the folder and its subfolders
  - dragging on the Mac, the context menu and the Files pane
  - uploading from the phone and the web page
  - a workflow that moves files to `done/`
  - why to narrow by `folder:`
  - committing dropped files or not
- `docs/how-to/set-up-a-workflow.md` — change: link the how-to and show a drop-box trigger.
- `docs/how-to/use-agents-in-a-browser.md` — change: the Drop box section on the project page.
- `docs/explanation/phone-and-ipad.md` — change: Add to Drop Box on the Remote.

## Assumptions

- **Alex's decisions in the issue stand**: one drop box per project; subfolders; the workflow owns the file; no limits; startup files don't fire; servers have theirs on the server; uploads from every app; not git-ignored; Mac drag onto a row; same name overwrites.
- **"No limits" binds the person's files, not the app's own state.** The seen list, the workflow queue and upload pieces are bounded (FR-010, FR-013, FR-017). The drop box itself is bounded only by the person seeing it (FR-020), and by the workflow, which owns the file.
- **Queueing is only for drop-box events.** Changing every event's in-flight behaviour is out of scope. A drop-box event names a file that waits, so queueing it is safe. Other events describe moments that pass.
- **The relay's 1 MB record** is why uploads are sent in pieces (`PhoneAttachment.swift:22`). On the local network the same pieces are used, to keep one path.
- **The watch is the existing one** (#173). The drop box adds a listener, not a second watch, and the drop box must not be added to the watch's exclusions.
- **The web page ships with its host**, so it changes with it. Phones may be older (FR-023, FR-024).
- **Each client's change is in this spec** (#233). The `Web/` row in `specs/071-web-remote/walks/parity.md` is updated by the build.

## Open questions for Alex

Each has the default this spec assumes. Claude (#229/#231 specs) needs Alex to confirm or change them before planning.

1. **Several files at once.** Today's one-run-in-flight rule would refuse all but one. Default: **queue** drop-box events per workflow and run them one at a time (FR-012). Alternative: one run gets every file that arrived while the last run was going, as a batch. Alex, queue or batch?
2. **Subfolder on a Mac drag.** Default: a plain drag onto a row goes to the top. Subfolders come from the row's context menu and from dropping onto a folder in the Files pane. Alternative: a spring-loaded menu of subfolders while hovering a row. Alex, is the context menu plus the Files pane enough?
3. **A warning line for a growing drop box.** Alex decided no caps, and this spec keeps that: the app never refuses or deletes. But to keep data visible, the default is to warn (a project-page strip and `dropbox.full`) past 1,000 files or 5 GB. Alex, is a warning acceptable under "no limits", and are those the right lines?
4. **The Remote's share sheet.** Default: not in this spec; Add to Drop Box lives on the project page. A share extension, "share to a project's drop box" from any app, is a natural follow-up. Alex, should it be in scope now?
5. **Files that arrived while the daemon was down.** Alex's rule is "files there at startup do nothing", and this spec follows it, so a file saved while the Mac was asleep and the daemon off is never announced. Alternative: remember the seen list across restarts, and announce files that are new since the last run. Startup would still not announce the first time a project is watched. Alex, which?
6. **System files.** Default: Finder's `.DS_Store`, `._*` and `Icon\r` files, and download part-files, never fire (FR-008). Alex, does that square with "no ignore list"?
7. **Folder matching.** Default: `folder: review` matches only `review/`, not `review/2026/`. Matching a folder and everything under it would need the globs of event matching step 2 (073). Alex, is exact enough for now?
