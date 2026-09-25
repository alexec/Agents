# Feature Specification: An Agent Can Work in a Worktree of Its Own

**Feature Branch**: `030-agent-worktrees`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Let the app start an agent in its own git worktree, using what we learned about the four ACP modes (Claude, Grok, Copilot, Cursor): the app creates the worktree itself and passes its path as the agent's working folder, since that is the only approach that works for all four. Provide a way for the user to select the worktree (new or existing). Decide how to name the worktree."

## Why this feature exists

Every agent in a project today works in the project folder itself. Two agents changing code at
once are changing the same files: one's half-finished edit breaks the other's build, a test run
picks up both sets of changes, and nobody can say afterwards which change came from which agent.
The person works around this by hand, making a worktree in a terminal and pointing a new project
at it, which files the agent under a different project and loses its place among the others.

A git worktree is the usual answer: a second checkout of the same repository, on its own branch,
in its own folder, sharing one history. Changes stay apart until someone merges them.

All four runtimes the app runs have a worktree option of their own, but checked on 2026-09-24,
none of them can be relied on when the app starts them over ACP:

| Runtime | Its own worktree option, when started over ACP |
|---------|-----------------------------------------------|
| Claude  | Works, but only through a per-session setting passed to the adapter, not a command-line flag. Makes `.claude/worktrees/<name>` and works there. |
| Cursor  | Makes a worktree under `~/.cursor/worktrees`, then works in the project folder anyway, because the folder the app names at session start wins. Also prints a stray line onto the protocol channel. |
| Copilot | Makes a worktree beside the project, then works in the project folder anyway. Never starts at all if the name matches an existing branch. |
| Grok    | Ignores the option, or refuses to start, depending on where it is placed. |

What every runtime *does* honour is the working folder the app gives it when a session starts.
So the app makes the worktree itself and starts the agent in it. One behaviour for all four
runtimes, the same place on disk whichever runtime runs, and nothing depends on a runtime's
flag surviving its next release.

## Clarifications

### Session 2026-09-24

- Q: How is a new worktree named? → A: From the prompt that starts the agent, with no typing: its first few words, and the branch is the same name under `agents/` (FR-006 to FR-008).
- Q: Where do the app's worktrees go? → A: Inside the repository, at `.agents/worktrees/<name>`, beside the app's workflows folder, with a local-only ignore entry (FR-009, FR-010).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start an agent in a new worktree (Priority: P1)

On a project that is a git repository, the start bar has a Worktree choice beside the folder.
It says **Project folder** until the person changes it. They choose **New worktree**, type what
they want done, and send. The app makes a new worktree on a new branch taken from where the project
folder is now, starts the agent there, and takes them into it. The agent appears in the project's
list with the others, with the worktree's name on its row. Its files pane, terminal and every
change it makes are in the worktree; the project folder is untouched.

**Why this priority**: This is the feature. Choosing an existing worktree, cleaning up and letting
agents do it are only worth having once an agent can be started in one.

**Independent Test**: In a git project, choose New worktree, send "add a line to README", and
check that a worktree and branch were made, the agent's edit is in the worktree and not the
project folder, and the agent is listed under the project. Repeat once for each of the four
runtimes.

**Acceptance Scenarios**:

1. **Given** a project that is a git repository, **When** the person opens the start bar, **Then** a Worktree choice sits beside the folder, set to Project folder.
2. **Given** New worktree is chosen, **When** the person sends a prompt, **Then** a worktree is made on a new branch based on the commit the project folder has checked out, and the agent starts with the worktree as its working folder.
3. **Given** the agent has started, **When** the person looks at the project's agent list, **Then** the agent is listed under the same project, and its row shows the worktree's name.
4. **Given** the agent edits a file, **When** the person looks at the project folder, **Then** the edit is not there; it is in the worktree, and the agent's files pane and terminal show the worktree.
5. **Given** any of Claude, Grok, Copilot or Cursor, **When** it is started in a new worktree, **Then** it works in that worktree and nowhere else.
6. **Given** the project is not a git repository, **When** the person opens the start bar, **Then** there is no Worktree choice and nothing else changes.

---

### User Story 2 - Start an agent in a worktree that already exists (Priority: P2)

The Worktree choice also lists the repository's existing worktrees: ones the app made, and ones
made any other way (in a terminal, or by a runtime's own worktree option). Each shows its name,
its branch, and which agents, if any, are working in it. The person picks one to send a second agent
into work already under way, for instance to review or test what the first agent did.

**Why this priority**: The request asks for it and it makes worktrees reusable, but a new worktree
on its own already delivers the separation.

**Independent Test**: Make a worktree in a terminal, open the Worktree choice, pick it, send a
prompt and check the agent works in that worktree and is filed under the project.

**Acceptance Scenarios**:

1. **Given** a repository with worktrees besides the project folder, **When** the person opens the Worktree choice, **Then** each is listed with its name, its branch, and the agents working in it.
2. **Given** an existing worktree is chosen, **When** the person sends a prompt, **Then** the agent starts in that worktree and nothing new is made.
3. **Given** an agent is already working in the chosen worktree, **When** the person chooses it, **Then** the choice says so, and a second agent can still be started there.
4. **Given** a listed worktree whose folder is missing, **When** the person opens the choice, **Then** it is shown as missing and cannot be chosen.

---

### User Story 3 - Worktrees are cleaned up by choice, never by accident (Priority: P2)

Archiving an agent never deletes its worktree: the work in it may not be merged yet. On the project
page the person can see the worktrees the app made and remove one when they are done with it. The
app refuses, and says why, while an agent is working there, and warns before removing one that holds
changes that are not committed or a branch that is not merged into the one it came from.

**Why this priority**: Without it, worktrees pile up on disk. But nothing is lost if this comes
later, because the person can remove them by hand in the meantime.

**Independent Test**: Archive an agent that worked in a worktree and check the worktree and its
branch remain. Remove it from the project page and check both are gone. Try again with an
uncommitted edit and check the warning appears first.

**Acceptance Scenarios**:

1. **Given** an agent working in a worktree, **When** it is archived, **Then** the worktree and its branch are left exactly as they are.
2. **Given** a worktree the app made with no agent working in it, **When** the person removes it from the project page, **Then** its folder is removed, and its branch too if it is merged.
3. **Given** a worktree with uncommitted changes or an unmerged branch, **When** the person asks to remove it, **Then** they are told what would be lost and must confirm.
4. **Given** an agent that is not archived is working in a worktree, **When** the person asks to remove it, **Then** removal is refused with the agent's name.

---

### User Story 4 - An agent can start its helpers in worktrees (Priority: P3)

An agent starting an agent of its own (feature 028) can ask for it to work in a new worktree, or in
an existing one, with the same naming and the same limits as the person has. Helpers doing separate
pieces of work in parallel then stop getting in each other's way.

**Why this priority**: Useful as soon as helpers do real parallel work, but it builds on every
story above and on 028.

**Independent Test**: Ask an agent to start a helper in a new worktree. Check the helper is filed
under the project, marked as started by the first agent, and working in its own worktree.

**Acceptance Scenarios**:

1. **Given** an agent with the tools from 028, **When** it starts a helper and asks for a new worktree, **Then** the helper starts in a new worktree named as in FR-006.
2. **Given** it names an existing worktree of the same repository, **When** it starts a helper, **Then** the helper starts there.
3. **Given** it names a folder that is not a worktree of the project's repository, **When** it starts a helper, **Then** the start is refused and it is told why.

---

### Edge Cases

- **The project folder is a subfolder of the repository.** The agent starts in the same subfolder of the worktree, so it sees the same part of the code it would have.
- **The project folder is itself a linked worktree.** The new worktree is made from the same repository; its base is whatever the project folder has checked out.
- **The project folder has uncommitted changes.** They stay in the project folder and do not carry into the new worktree. The New worktree choice says it starts from the last commit.
- **The repository has no commits.** A worktree cannot be made. New worktree is shown disabled, and its note says why.
- **Detached HEAD in the project folder.** The new branch starts from the checked-out commit.
- **The name is already taken, as a folder or as a branch.** The next free name is used (`-2`, `-3`, …). Never reuse a branch or folder that already exists: this is the case that stops Copilot from starting at all.
- **Making the worktree fails** (disk full, locked index, a hook refuses). No agent is started. The prompt stays in the bar, and the error is shown where it was sent.
- **An agent's worktree is removed outside the app.** On resume or restart (feature 025), the agent does not quietly start in the project folder instead. It shows that its worktree is gone, and it cannot be resumed until the person chooses a folder.
- **Untracked setup is missing** (dependencies, local settings, build output). A new worktree has only what git tracks. The app does not copy or set anything up; the agent can if asked.
- **The project folder has the app's `.agents/` folder in it.** Worktrees made there must never show up as changes in the project, nor in a search of it that respects git's ignore rules.

## Requirements *(mandatory)*

### Functional Requirements

**Choosing**

- **FR-001**: The start bar MUST offer a Worktree choice whenever the chosen folder is inside a git repository, and MUST NOT show it otherwise.
- **FR-002**: The choice MUST offer **Project folder** (the default, today's behaviour), **New worktree**, and every existing worktree of that repository other than the project folder.
- **FR-003**: Each existing worktree MUST show its name, its branch (or that it is detached), and the agents working in it. Missing worktrees MUST be shown and MUST NOT be choosable.
- **FR-004**: The choice MUST reset to Project folder after each start. A worktree is a per-agent decision, not a sticky setting.
- **FR-005**: On a project page, where the folder cannot be changed, the Worktree choice MUST still be available.

**Naming**

- **FR-006**: A new worktree MUST be named from the prompt that starts the agent: its first few meaningful words, lower-case, joined with hyphens, at most 32 characters (for example "Fix the login redirect on Safari" gives `fix-login-redirect-safari`). A prompt with no usable words (only an attachment, or only symbols) gives `agent-` plus a short date and time.
- **FR-007**: The branch MUST be the name under an `agents/` prefix (`agents/fix-login-redirect-safari`), so the app's branches sort together and cannot clash with the person's own.
- **FR-008**: If the folder or the branch already exists, the app MUST add the next free number to both. It MUST NOT reuse, reset or check out an existing branch for a new worktree.
- **FR-009**: The worktree folder MUST be `<repository root>/.agents/worktrees/<name>`, the same for all four runtimes.
- **FR-010**: The app MUST keep its worktrees out of the project's changes and searches without editing any file the project tracks. A local-only ignore entry does this, where git's standard ignore rules are respected.

**Starting**

- **FR-011**: The app MUST make the worktree itself before starting the runtime, and MUST start the runtime with the worktree (or the matching subfolder of it) as its working folder.
- **FR-012**: The app MUST NOT use any runtime's own worktree option. Nothing about worktrees may differ between Claude, Grok, Copilot and Cursor.
- **FR-013**: If making the worktree fails, the app MUST NOT start the agent, MUST keep the prompt, and MUST show the reason.

**Belonging**

- **FR-014**: An agent working in a worktree MUST be filed under the project the worktree was made from. That includes the project's list, its archive, its cost, and the limit on agent-started agents (028), just like an agent in the project folder.
- **FR-015**: Every place that shows or uses an agent's folder MUST use the worktree: the files pane, the terminal, the list of the runtime's sessions, and what the agent is allowed to reach.
- **FR-016**: The agent's row and its page MUST show the worktree's name. Its tooltip or detail MUST show the branch and the full path.
- **FR-017**: An agent MUST resume and restart in the worktree it was started in, and MUST NOT fall back to the project folder if the worktree is gone.

**Cleaning up**

- **FR-018**: Archiving or deleting an agent MUST NOT remove its worktree or branch.
- **FR-019**: The project page MUST list the worktrees the app made for that project, with the agents in each, and MUST offer to remove each one.
- **FR-020**: Removal MUST be refused while any agent that is not archived works in the worktree. Before removing a worktree with uncommitted changes or an unmerged branch, the app MUST say what would be lost and wait for confirmation. The branch MUST be deleted only if it is merged, or if the person confirmed.
- **FR-021**: The app MUST NOT remove worktrees it did not make.

**Agents starting agents**

- **FR-022**: The tool from 028 that starts an agent MUST accept a request for a new worktree, or the name of an existing worktree of the same repository. It MUST apply FR-006 to FR-013, and MUST refuse anything outside the project's repository.

### Key Entities

- **Worktree**: A second checkout of the project's repository, in its own folder, on its own branch. Has a name, a folder, a branch (or a detached commit), whether the app made it, and whether its folder still exists.
- **Agent**: Gains the worktree it works in, if any. Its project stays the project it was started from, not the folder it works in.
- **Project**: Unchanged, one folder. Gains a list of the worktrees the app made for it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Starting an agent in a new worktree takes one choice more than starting one today, and no typing beyond the prompt.
- **SC-002**: Each of the four runtimes, started in a new worktree, makes every file change in that worktree and none in the project folder. Checked by one run per runtime.
- **SC-003**: Two agents started in separate new worktrees from the same project at the same moment get two different worktrees and branches, every time.
- **SC-004**: No worktree or branch is ever lost by archiving an agent, restarting the app or resuming an agent. Checked by archiving, restarting and resuming with uncommitted work in a worktree.
- **SC-005**: A person can tell which worktree an agent is in from the project's agent list, without opening the agent.
- **SC-006**: After worktrees are in use, the project folder's git status shows nothing that the app made.

## Assumptions

- **Base**: A new worktree starts from the commit the project folder has checked out. Choosing a different base branch is left out; the agent can switch branches if asked.
- **Merging is not the app's job.** Getting the work back into the main branch is done by the agent or the person, with git, as today. A merge or pull-request action could come later.
- **No setup is copied.** Dependencies, local settings and build output are not brought into a new worktree. Runtime-specific setup files (such as Cursor's) are not run.
- **Renaming** a worktree after it is made is left out.
- **The phone** (029) and **workflows** (017) start agents without a Worktree choice in this feature. Both can take the same choice later, since it lives in the daemon's start request.
- **Worktrees the runtimes make themselves** (such as `.claude/worktrees`) are listed like any other worktree (US2), but are not treated as made by the app, and the app never removes them.
- **The findings about the runtimes' own options** are from Claude adapter 0.81.2, Copilot CLI 1.0.89, and the Grok and Cursor versions installed on 2026-09-24. They are the reason for FR-012, not something this feature depends on.
