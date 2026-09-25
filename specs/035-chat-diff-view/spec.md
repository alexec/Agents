# Feature Specification: What the Agent Changed, Beside the Conversation

**Feature Branch**: `035-chat-diff-view`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Add diff view support to the chat right sidebar. Lean into ACP if possible, and git if not."

## Why this feature exists

To find out what an agent changed today, the person scrolls the conversation. Each edit is shown
where it happened, as a small old-then-new block, between the agent's messages and its other tool
calls. That answers "what is it doing now". It does not answer the question the person has at the
end: **what did it change, all together, and is that right?** For that they open a terminal and
run `git diff`, or they open each marked file in the files pane and read it whole, with no way to
see which lines are new.

The right sidebar already holds the agent's folder, a terminal, a browser and what was exchanged.
A fifth pane, **Changes**, answers the end-of-turn question in one place: the files this agent
changed, and for each, what changed in it.

### Where the changes come from

Two sources can say what changed, and they are not equal.

**The runtime, over ACP.** When an agent edits a file through its own tools, its runtime can send
the edit as a `diff` in the tool call: the path, the text before and the text after. Checked on
2026-09-24 against every transcript the daemon has kept:

| Runtime | Agents | With diffs | What a diff carries |
|---------|--------|-----------|---------------------|
| Claude  | 194    | 68        | 1,168 edits. For an edit, the replaced passage and its replacement, not the whole file. For a new file, no old text. |
| Copilot | 1      | 1         | One edit. Too few to say more. |
| Grok    | 2      | 0         | None. |
| Cursor  | 0      | —         | Not seen. |

ACP is the better source where it exists: it says which agent made the change, when, and in which
turn, even in a folder several agents share. It is already in the transcript, costs nothing to
read, and works for an agent the person is reading from a folder that has since moved on. What it
cannot see is a change made any other way: a shell command, a formatter, a code generator, a
`git checkout`. And some runtimes send nothing.

**Git.** Where the agent's folder is a git repository, git can say what is different in the
folder, whoever did it and however. It sees every change and knows nothing about who made it.

So the pane leans on ACP, and asks git only for what ACP cannot say (FR-005 to FR-009).

## Clarifications

### Session 2026-09-24

- Q: In the shared project folder, what does the pane take from git? → A: Every uncommitted change git sees, with what the agent did not report marked as seen in the folder (FR-006, FR-008).
- Q: Read only, or can the pane undo changes? → A: Read only (FR-016).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See every file the agent changed, and what changed in it (Priority: P1)

An agent has spent a few turns working. The person opens the sidebar and chooses **Changes**.
They see a list of the files the agent changed, in the order it first changed them, each with a
count of what changed. They choose one and read its changes: every edit the agent made to that
file, in order, each showing the lines that went and the lines that came. They choose the next.
They never leave the conversation's window and never open a terminal.

**Why this priority**: This is the feature. Everything else here improves what the list shows or
where it comes from.

**Independent Test**: Start a Claude agent, ask it to edit two files and create a third. Open
Changes. All three are listed; each shows exactly the edits the conversation shows for it, in the
same order; the new file shows as new.

**Acceptance Scenarios**:

1. **Given** an agent that has edited `a.swift` twice and created `b.md`, **When** the person
   opens Changes, **Then** both files are listed, `a.swift` first, `a.swift` with two edits and
   `b.md` marked as new.
2. **Given** the Changes pane is open, **When** the agent makes another edit, **Then** the edit
   appears in the pane without the person doing anything, and the pane does not move what they are
   reading.
3. **Given** an agent that has changed nothing, **When** the person opens Changes, **Then** the
   pane says it has changed nothing yet, not an empty white space.
4. **Given** a file in the list, **When** the person chooses to open it, **Then** the files pane
   opens that file at the first changed line.

---

### User Story 2 - From an edit in the conversation to the pane (Priority: P2)

Reading the conversation, the person sees an edit and wants to see it among the rest of that
file's changes. They choose the edit, and the sidebar opens on Changes at that file, with that
edit in view.

**Why this priority**: It joins the two places a change is shown, so the pane is where the person
goes rather than a second copy of the conversation they have to find their way around.

**Independent Test**: In a conversation with edits to three files, choose the second edit to the
middle file. The sidebar opens (if closed) on Changes, with that file chosen and that edit in view.

**Acceptance Scenarios**:

1. **Given** the sidebar is closed, **When** the person chooses an edit in the conversation,
   **Then** the sidebar opens on Changes at that edit.
2. **Given** an edit to a file the agent later deleted, **When** the person chooses it, **Then**
   the pane shows the file, marked as deleted, with its edits still readable.

---

### User Story 3 - Changes the runtime did not report (Priority: P2)

An agent runs a formatter over the project, or is a Grok agent, which sends no diffs at all. In a
git repository the pane still shows what changed: files ACP knows nothing about are listed with
what git says changed in them, marked as seen in the folder rather than reported by the agent.

**Why this priority**: Without it, the pane is wrong about half the time for some runtimes and
silently incomplete for all of them, and a list that is sometimes incomplete is one the person
cannot trust to be complete.

**Independent Test**: In a git project, start a Grok agent and have it edit a file. Changes lists
the file with git's view of the change. Separately, have a Claude agent run a formatter through
its shell; the formatted files appear, marked as not reported by the agent.

**Acceptance Scenarios**:

1. **Given** a runtime that sends no diffs, in a git repository, **When** it edits a file,
   **Then** the file appears in Changes with what git says changed.
2. **Given** a Claude agent whose edit to `a.swift` was reported and which then ran a formatter
   that changed `a.swift` and `c.swift`, **When** the person opens Changes, **Then** `a.swift`
   shows its reported edits and says the file has since changed in ways not reported; `c.swift`
   is listed as changed in the folder.
3. **Given** a folder that is not a git repository and a runtime that sends no diffs, **When** the
   person opens Changes, **Then** the pane says this agent's runtime does not report its changes
   and this folder is not tracked by git, so there is nothing it can show.

---

### User Story 4 - The whole file, as it now stands (Priority: P3)

A reported edit shows a passage, not the file. To judge whether the change is right the person
sometimes needs the file around it. In a git repository they can switch the file to **Whole
file**, which shows the file as it now is with every line that differs from where the agent
started marked, and the lines that went shown where they were.

**Why this priority**: The per-edit view answers most questions. This one answers "what does the
file look like now" without leaving for the files pane, and it is the only view that composes many
small edits into one.

**Independent Test**: Have an agent make three edits to one file in a git repository. Switch the
file to Whole file; every changed line is marked, and nothing else is.

**Acceptance Scenarios**:

1. **Given** a file with three reported edits in a git repository, **When** the person switches to
   Whole file, **Then** they see the file's current text with the changed lines marked against
   where the agent started.
2. **Given** a folder that is not a git repository, **When** the person looks at a file, **Then**
   the Whole file choice is not offered.

---

### Edge Cases

- **A shared folder.** Several agents working in the same project folder. What git sees there is
  everyone's. The pane shows this agent's reported edits as its own, and marks what came from git
  as seen in the folder, not attributed to this agent (FR-008).
- **A worktree agent.** An agent in its own worktree (030) owns its folder, so what git sees there
  is its work, including anything it has committed since it started (FR-009).
- **The agent commits.** Committed changes do not disappear from the pane: "where the agent
  started" is fixed when it starts, not the folder's latest commit.
- **A reported edit that no longer applies.** The agent edited a passage and later rewrote the
  file. The earlier edit is still shown, in order, as history; the pane does not pretend it is
  still in the file.
- **A file outside the agent's folder.** Listed with its full path, and never given to git.
- **A huge change.** A generated file, a lockfile, a thousand-line rewrite. The file is listed with
  its count, and its changes are shown on request, not rendered up front.
- **A binary file.** Listed as changed; its contents are not shown.
- **An agent restored after a restart (025).** Its reported edits come back with its transcript;
  git is asked again.
- **Colour.** The app keeps colour for something having gone wrong, and the conversation's edits
  already show change by mark and weight rather than red and green. The pane does the same.

## Requirements *(mandatory)*

### Functional Requirements

**The pane**

- **FR-001**: The right sidebar MUST have a Changes pane beside Files, Terminal, Browser and
  Exchanged, for the agent the conversation is showing.
- **FR-002**: The pane MUST list each file the agent changed once, in the order it was first
  changed, with its path relative to the agent's folder, a count of lines added and removed where
  that can be known, and a mark for new, deleted, binary or not-reported-by-the-agent.
- **FR-003**: Choosing a file MUST show its changes; choosing to open it MUST open it in the files
  pane at its first changed line.
- **FR-004**: The pane MUST update as the agent works, without the person asking and without
  moving what they are reading.

**Where changes come from**

- **FR-005**: Every change the runtime reports over ACP MUST be taken from the transcript and shown
  as that agent's, grouped under its file, in the order made.
- **FR-006**: Where the agent's folder is in a git repository, the pane MUST also ask git what has
  changed since the agent started, and list any changed file ACP did not report, marked as seen in
  the folder rather than reported.
- **FR-007**: A file ACP did report, which git shows has changed beyond what was reported, MUST say
  so, and MUST offer git's view of it.
- **FR-008**: For an agent in a folder it shares (the project folder), git's view MUST be the
  folder's uncommitted changes, marked as possibly including other agents' and the person's
  work. It MUST NOT be presented as this agent's alone.
- **FR-009**: For an agent in its own worktree, git's view MUST be everything that differs from the
  commit the worktree was made from — committed or not — and may be presented as the agent's.
- **FR-010**: Where neither source can say anything, the pane MUST say which is missing and why,
  rather than showing an empty list that reads as "nothing changed".

**Reading a change**

- **FR-011**: A reported edit MUST show the lines removed and the lines added, as the conversation
  already does; a new file MUST show as new, with its contents.
- **FR-012**: In a git repository, a file MUST also be viewable whole: its current text with changed
  lines marked and removed lines shown where they were.
- **FR-013**: Change MUST be shown by mark and weight, not by red and green.
- **FR-014**: Choosing an edit in the conversation MUST open the sidebar on Changes at that file
  and edit.
- **FR-015**: A file with more than a screenful of changes MUST be listed straight away and have its
  changes drawn when chosen, so one generated file does not slow the pane.

**Limits**

- **FR-016**: The pane MUST be read-only. It does not stage, commit, revert or edit anything.
- **FR-017**: Asking git MUST NOT change the repository in any way: no index refresh written, no
  lock taken that could collide with the agent's own git commands.
- **FR-018**: Git MUST NOT be asked more often than changes can happen: on opening the pane, on a
  reported edit, and on the agent's turn ending, not on a timer.

### Key Entities

- **Changed file**: a path the agent changed, with where the knowledge came from (reported, seen
  in the folder, or both), its state (changed, new, deleted, binary) and its counts.
- **Reported edit**: one diff from the runtime: path, text before (absent for a new file), text
  after, and the tool call and turn it came in.
- **Starting point**: what "changed since the agent started" is measured against: the commit the
  worktree was made from, or the commit the shared folder was on when the agent started.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After an agent's turn, the person can say which files it changed and read each change
  without opening a terminal or the files pane, in every case the Independent Tests above describe.
- **SC-002**: For a Claude agent, every edit the conversation shows appears in the pane under the
  right file, in the right order: none missing, none duplicated, checked against a transcript of at
  least 50 edits.
- **SC-003**: For every runtime, in a git repository, every file git shows changed since the agent
  started appears in the pane.
- **SC-004**: The pane opens on an agent with 200 changed files in under a second, and choosing any
  file shows its changes in under half a second.
- **SC-005**: No repository is changed by the pane being open: `git status` and the index are the
  same before and after.
- **SC-006**: No file in a shared folder is shown as the agent's own unless the agent reported
  changing it.

## Assumptions

- Mac only. The phone and iPad chat are 033's and 034's; 034's touched-file sheet is the natural
  place for this later, and nothing here should stop it reusing the same list.
- "Where the agent started" in a shared folder is the commit the folder was on when the agent
  started. The daemon records it then; an agent started before this feature has none, and the
  pane falls back to uncommitted changes.
- Reported edits are passages, not files, so the per-edit view is the only one ACP can give on its
  own. Composing them into a whole-file view needs git, which is why Whole file is git-only.
- Cursor's and Copilot's diffs are assumed to have the same shape as Claude's. Too few were seen
  to know; the plan should check each runtime once.
- Reverting a change from the pane is out of scope (FR-016). The agent, the terminal, or git are
  where that is done.
- The existing touched-file mark in the files pane stays; the Changes pane does not replace it.
