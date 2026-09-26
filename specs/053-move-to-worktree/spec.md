# Feature Specification: An Agent Can Move into a Worktree Mid-Work

**Feature Branch**: `agents/053-move-to-worktree`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Agent moves itself into a worktree mid-work. An agent that started in the project folder (or any folder) can ask the app to move it into a new git worktree between turns: the daemon makes the worktree with feature 030's machinery (name, branch from the checked-out commit, recorded as app-made so archive cleanup applies), updates the agent's folder, and restarts the runtime session there so the conversation carries on (picking up the runtime's session, or a new one with the transcript kept). The Changes pane, resume after restart and archive cleanup all follow the new folder. The person can do the same from the app. Claude's own EnterWorktree/ExitWorktree are removed so there is one way to move. Moving happens only between turns — the agent asks, and the move takes effect when its turn ends."

## Why this feature exists

Feature 030 lets an agent *start* in a worktree. The choice has to be made before the first
prompt is sent, and often nobody knows yet. An agent is asked a question, reads the code, and
only then finds out the answer is a change big enough to need its own branch. Today it has two
ways out, and both are bad:

- **Claude's own worktree tool.** Claude agents can call Claude Code's `EnterWorktree`, which
  the app does not remove. The runtime then works in `.claude/worktrees/<name>`, but the app
  still thinks the agent is in the project folder. The Changes pane shows the wrong folder.
  Archiving never cleans the worktree up, because 030 does not count it as the app's. After a
  restart the agent resumes in the project folder, which is exactly what 030's FR-017 forbids.
  Only Claude has this tool, so the same agent on Grok, Copilot or Cursor cannot move at all.
- **Start again.** The person starts a new agent in a new worktree and re-explains everything.
  The conversation so far is lost to it.

Only the app can make a move that everything else follows. It makes the worktree with 030's
rules, changes the agent's folder and starts the runtime again there. That works the same on
all four runtimes, because the one thing every runtime honours is the folder it is given when a
session starts (030's finding). Restarting the session is also why a move can only happen
between turns.

## Clarifications

### Session 2026-09-25

- Q: What happens to edits the agent already made in the old folder that are not committed? → A: They are left behind, as in 030. The new worktree starts from the old folder's last commit, and nothing uncommitted comes with it (FR-009, FR-010).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The agent asks to move, and carries on in the worktree (Priority: P1)

An agent working in the project folder decides its work needs a branch of its own. It asks
the app for a new worktree, and the app says the move will happen when the turn ends. The agent
ends its turn. The app makes the worktree, moves the agent into it and starts the runtime there.
The agent then picks up where it left off without anyone typing: the conversation is all still
there, and a line in the chat says it moved, with the worktree's name and branch. From then on
its row shows the worktree's name, and its files pane, terminal and Changes pane all show the
worktree.

**Why this priority**: This is the feature. The agent is usually the first to know that it needs
a branch, and on three of the four runtimes it has no way to get one today.

**Independent Test**: In a git project, start an agent in the project folder and ask it to "move
into a worktree of your own, then add a line to README". Check that a worktree and branch were
made under `.agents/worktrees/`, that the agent carried on by itself, that the edit is in the
worktree and not the project folder, and that the Changes pane shows it. Do this once on each of
the four runtimes.

**Acceptance Scenarios**:

1. **Given** an agent in the project folder of a git project, **When** it asks for a new worktree, **Then** it is told the move will happen when its turn ends, and nothing moves while the turn is still going.
2. **Given** the agent's turn has ended after it asked, **When** the move happens, **Then** a worktree is made by 030's rules (name, `agents/` branch, `.agents/worktrees/` folder, from the commit the old folder has checked out), and it is recorded as made by the app.
3. **Given** the worktree has been made, **When** the runtime starts again in it, **Then** the conversation is all still in the chat, a line says the agent moved and where to, and the agent starts a turn by itself so it can carry on.
4. **Given** the agent has moved, **When** the person looks at its row, files pane, terminal or Changes pane, **Then** each one shows the worktree, and the project folder is untouched from then on.
5. **Given** any of Claude, Grok, Copilot or Cursor, **When** it moves, **Then** it works in the new worktree and nowhere else.

---

### User Story 2 - Everything that follows a folder follows the move (Priority: P1)

The move is not just what the runtime sees. Once the agent has moved, the app treats it exactly
as if it had been started in that worktree: restarting the app, resuming the agent, archiving it
and the project page's worktree list all use the new folder.

**Why this priority**: Without this, a move is a slower version of Claude's `EnterWorktree`: work
in a folder the app loses track of. It is part of the P1 slice, not an extra.

**Independent Test**: Move an agent, restart the app, and check that it resumes in the worktree.
Commit everything, archive it, and check that the worktree is removed by 030's cleanup rules.

**Acceptance Scenarios**:

1. **Given** an agent that has moved, **When** the app restarts or the agent is resumed, **Then** it resumes in the worktree, never in the folder it came from.
2. **Given** an agent that has moved and has nothing uncommitted, **When** it is archived as the last agent in that worktree, **Then** the worktree goes, and its branch too if it is merged, just as for an agent started there (030 FR-018).
3. **Given** an agent that has moved, **When** the person opens the project page, **Then** the worktree is listed with the app's worktrees, with that agent in it.
4. **Given** the runtime cannot pick up its own session in the new folder, **When** the move happens, **Then** the agent carries on in a new runtime session with the whole conversation kept, and the chat says so. The agent is not lost.

---

### User Story 3 - The person moves an agent from the app (Priority: P2)

While an agent is between turns, the person can move it from its page: to a new worktree, to an
existing worktree of the same repository, or back to the project folder. It is the same Worktree
choice as 030's start bar, and the same move behind it. A move the person makes does not start a
turn. The agent learns where it is at the start of its next turn.

**Why this priority**: The person often sees the need before the agent does. It builds on the same
move as US1, so it costs little once that exists.

**Independent Test**: With an agent idle in the project folder, choose New worktree from its page.
Check that it moved, that no turn started, and that the next prompt is answered from the worktree.

**Acceptance Scenarios**:

1. **Given** an agent between turns in a git project, **When** the person opens its page, **Then** they can move it to a new worktree, to any existing worktree of the repository, or to the project folder.
2. **Given** an agent in the middle of a turn, **When** the person tries to move it, **Then** they are told the move will happen when the turn ends, and can take it back until then.
3. **Given** the person has moved an agent, **When** the move is done, **Then** no turn starts. At its next turn the agent is told which folder it is now in.

---

### User Story 4 - One way to move (Priority: P2)

A runtime's own tool for moving into a worktree is taken away from agents the app runs, so the
only move there is the app's. Today that is Claude's `EnterWorktree` and `ExitWorktree`.

**Why this priority**: As long as Claude's own tool is there, an agent can still drift into a
folder the app cannot see, and US2's promises do not hold for it.

**Independent Test**: Start a Claude agent and ask it to use `EnterWorktree`. Check that it does
not have that tool, and uses the app's move instead.

**Acceptance Scenarios**:

1. **Given** a Claude agent, **When** it lists its tools, **Then** `EnterWorktree` and `ExitWorktree` are not there, and the app's move is.
2. **Given** a runtime gains its own worktree-moving tool later, **When** the app's tool check runs (015), **Then** the new tool is reported so that it can be removed too.

---

### Edge Cases

- **The agent asks twice in one turn.** The last request wins. Only one move happens when the turn ends.
- **The agent asks and the turn ends in a failure or a stop.** The move still happens when the turn ends however it ended, unless the person took it back. It does not start a turn by itself after a stop.
- **Making the worktree fails** (no commits, disk full, locked index, a hook refuses). The agent stays where it was, the chat says why, and the runtime is not restarted. If it was the agent that asked, it is started again and told the reason, so that it can decide what to do.
- **The runtime will not start again in the new folder.** The worktree is kept (nothing in it yet is lost). The agent shows that it could not start, in the new folder, like any failed resume (025). It does not go back to the old folder by itself.
- **The project is not a git repository.** The agent is told that a move needs a git repository. The person's page offers no move.
- **The agent is already in a worktree.** It can move to a new worktree. The new one is made from what its current folder has checked out, not the project folder, so its commits come along.
- **The old folder was a worktree the app made, and the agent was the last one in it.** The move leaves that worktree where it is. Cleaning it up stays with 030's project-page removal.
- **Moving to an existing worktree another agent is working in.** Allowed, as in 030 US2, and the choice says who is there.
- **The folder the agent had open was a subfolder of the repository.** It lands in the same subfolder of the worktree (030's rule).
- **Additional folders the agent was given.** These stay as they were. Only its working folder changes.
- **A helper the agent started (028).** Helpers stay where they are. Moving one agent never moves another.
- **Claude's own worktrees made before this feature.** These are still listed like any other worktree (030 US2) and never removed by the app. An agent that is in one resumes there.
- **The agent is on a server (037).** The move works the same way on the server, in the server's copy of the repository.

## Requirements *(mandatory)*

### Functional Requirements

**Asking**

- **FR-001**: Agents MUST have a tool from the app to ask for a move: to a new worktree, to an existing worktree of the same repository by name, or back to the project folder. A new worktree MAY be given a name. Otherwise it is named from the agent's title by 030's naming rules (FR-006 to FR-008), falling back to `agent-` plus a short date and time.
- **FR-002**: The tool MUST answer at once, before anything moves: either that the move will happen when the turn ends, or why it cannot (not a git repository, not a worktree of this repository, a name it cannot use).
- **FR-003**: The person MUST be able to ask for the same moves from the agent's page on the Mac, using 030's Worktree choice. While a turn is running, the choice MUST say that it waits for the turn to end, and a waiting move MUST be possible to take back.
- **FR-004**: Only one move MAY be waiting at a time. A later request replaces it.

**Moving**

- **FR-005**: A move MUST happen only between turns: after the turn in which it was asked has ended, or at once if the agent was already between turns.
- **FR-006**: A new worktree MUST be made by 030's rules (FR-006 to FR-011): its folder, its `agents/` branch, and kept out of the project's changes. It MUST be recorded as made by the app.
- **FR-007**: After the worktree exists, the app MUST change the agent's working folder, save it, and start the runtime again with the new folder (or the matching subfolder of it). The same app tools, runtime settings, tool removals and additional folders MUST apply as before.
- **FR-008**: The runtime MUST be asked to pick up its own session in the new folder. If it cannot, the agent MUST carry on in a new runtime session with the whole conversation kept and its briefing given again, and the chat MUST say so.
- **FR-009**: A new worktree MUST start from the commit the agent's old folder has checked out. Nothing that is not committed in the old folder MAY be carried into it, and nothing in the old folder MAY be changed or removed by a move.
- **FR-010**: The tool's answer and the chat line for the move MUST say that uncommitted changes stay behind, and MUST name how many files that is when there are any.
- **FR-011**: If any step fails before the runtime has started in the new folder, the agent MUST stay in its old folder with its runtime running there, and the chat MUST say what failed. A worktree that was already made MUST be kept, not removed.

**After the move**

- **FR-012**: The chat MUST show a line for every move: from where, to where, the branch, and whether the runtime's session was picked up or a new one begun.
- **FR-013**: When the agent itself asked, it MUST be started again by itself after the move, told which folder it is now in, and left to carry on. When the person moved it, no turn MAY start. The agent MUST instead be told at the start of its next turn.
- **FR-014**: From the move on, every place that shows or uses the agent's folder MUST use the new one: its row, page, files pane, terminal, Changes pane, the list of the runtime's sessions, and what the agent is allowed to reach (030 FR-015, FR-016).
- **FR-015**: Resume and restart (025) MUST use the new folder. If it is gone, 030 FR-017 applies: the agent does not fall back to the folder it came from.
- **FR-016**: Archive cleanup and the project page's worktree list MUST treat a moved-into worktree exactly like one the agent was started in (030 FR-018 to FR-021).
- **FR-017**: Other clients (the phone and iPad Remote) MUST show the agent's new folder and the move's chat line. Moving an agent from the phone is out of scope here.

**One way to move**

- **FR-018**: Claude's `EnterWorktree` and `ExitWorktree` MUST be removed from agents the app runs, in the same way as the other removed tools (015).
- **FR-019**: The tool check from 015 MUST treat a runtime's own worktree-moving tool as something to remove, so that a new one gets reported.

### Key Entities

- **Agent**: Its working folder can now change during its life. Gains at most one waiting move, and a history of moves shown in its chat.
- **Waiting move**: Where the agent will go (new worktree with an optional name, an existing worktree, or the project folder), who asked (the agent or the person), and when.
- **Worktree**: As in 030. One made by a move is recorded as made by the app, the same as one made at start.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An agent can go from the project folder to its own worktree and carry on with no typing by the person, on each of the four runtimes. Checked by one run per runtime.
- **SC-002**: After a move, no file change the agent makes lands in the folder it left. Checked by one run per runtime.
- **SC-003**: After a move, restarting the app and resuming the agent puts it back in the worktree 100% of the time.
- **SC-004**: No uncommitted change is ever lost or moved by a move, in either folder.
- **SC-005**: A move is done, from the end of the turn to the agent working again, within the time a normal resume (025) takes, plus the time to make the worktree.
- **SC-006**: No agent the app runs has a runtime-owned way to move into a worktree.

## Assumptions

- **Built on 030.** Worktree naming, folders, branches, the "made by the app" record, cleanup and the Worktree choice all come from 030 and are not specified again here.
- **Restarting the runtime is the only way to move.** No runtime lets a client change a session's folder while it runs, which is why a move waits for the turn to end.
- **Runtimes may not find their own session in a new folder.** Some runtimes keep sessions per folder. For those, FR-008's new session with the conversation kept is the normal path, not a failure.
- **The agent starting itself again after its own move** is deliberate: it asked in order to carry on working, so waiting for the person would stall it.
- **Uncommitted edits stay behind** (Clarification). An agent that wants its edits in the worktree commits them, or makes them again, after it moves.
- **Moving from the phone** and moving a whole group of agents at once are left out.
- **Related:** 052 (runtime quota fallback) also restarts a chat in a new runtime session with the conversation kept. Both should use the same carry-on path.
