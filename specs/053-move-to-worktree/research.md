# Research: An Agent Can Move into a Worktree Mid-Work

## R1. How a move restarts the runtime

**Decision**: Don't add a restart. Apply the move between the turn-end release and the next
start that already happen.

**Rationale**:
- `finishTurn` calls `releaseRuntime(for:)` after every turn ("a finished agent's process is let
  go", `DaemonCore+Commands.swift`).
- The next prompt goes through `liveSession(for:)`. That launches in `agent.cwd` and calls
  `continueSession(id:cwd: agent.cwd, …)`, falling back to `newSession` with the briefing again.
- So rewriting `agent.cwd` and `agent.worktree` after the release is the whole of "restart the
  runtime there".
- It also means a move the person makes while the agent is idle can be applied at once: no
  runtime is running to stop.
- `liveSession`'s existing 030 check (`worktreeMissing`, FR-017) protects the new folder on
  resume for free.

**Alternatives considered**:
- *End the live session and start another straight away.* This duplicates `liveSession`, and
  it's pointless for the agent's own move, since the next turn starts one anyway.
- *Change the folder inside a live session.* No ACP method for it exists. It's also why the spec
  moves only between turns.

## R2. Claude picks its session back up from another folder

**Finding (2026-09-25, Claude Code CLI on this Mac)**:
1. `claude -p` in `/tmp/cwdspike/a` was told to remember "PELICAN", giving session `edcb0f86…`.
2. `claude -p --resume edcb0f86…` was run from `/tmp/cwdspike/b`.
3. It answered "PELICAN", with the same session id.
4. The session file stayed under `~/.claude/projects/-private-tmp-cwdspike-a/`.

The adapter (`@agentclientprotocol/claude-agent-acp` 0.81.2) implements `session/resume` as
`getOrCreateSession(params)` with the client's `cwd`, on the same SDK.

**Decision**: Expect Claude to keep its session across a move. Phase 0 confirms it through the
adapter, not only the CLI.

**Confirmed through the adapter (T003, 2026-09-25, `RuntimeMoveLiveTests`)**: after
`session/resume` in folder B, Claude answered PELICAN.

## R3. Grok, Cursor and Copilot

**Finding (filesystem only, not yet run)**:
- Grok keeps sessions under `~/.grok/sessions/<percent-encoded cwd>/`.
- Cursor keeps them under `~/.cursor/chats/<hash>/`, and the hash looks derived from the folder.
- Copilot keeps them under `~/.copilot/session-state/<id>/`, which doesn't depend on the folder.

So Grok and Cursor may answer `session/resume` or `session/load` in a new folder with "not found".

**Decision**:
- Phase 0 is a live check per runtime (`RuntimeMoveLiveTests`), as a gate.
- A runtime that fails still carries on through the existing fallback (new session, briefing
  again, the chat line FR-008 asks for), but it has lost its memory. For those, R5's handover
  applies.

**Measured (T003, 2026-09-25, `RuntimeMoveLiveTests`, through each ACP adapter)**:

| Runtime | Continued in folder B | Remembered |
|---------|----------------------|------------|
| Claude | yes | yes |
| Copilot | yes | yes |
| Cursor | yes | yes (the hash was not the folder, or its load looks further) |
| Grok | **no**: `session/load` answers `-32603 Path not found` (`FS_NOT_FOUND`) | — |
| Codex | yes (measured 2026-09-26 on the app's own copy) | yes |
| Gemini, Antigravity | not measured: each needs a credential the daemon lends at launch, which the bare test does not have | |

**Decision (Alex, 2026-09-26)**: runtimes that do not carry their conversation are left out of
moving altogether: `RuntimeCatalog.carriesConversationAcrossFolders` lists the ones measured to
(Claude, Copilot, Cursor, Codex). The rest get no move tools (`--no-move-tools`), the daemon
refuses to move them, and the page shows the Worktree choice disabled with the reason. So
Handover (R5) is not needed for moves; 052 still needs its own.

So Grok alone loses its conversation on a move. Through today's fallback it carries on in a new
session with the briefing again, and has forgotten everything it was told. `runtime-tools.sh grok`
lists no worktree-moving tool (Grok's list is an allow-list, and nothing new was found).

**Rejected**: copying or linking the runtime's session file into the new folder's key before
resuming. It's the runtime's private storage, it differs per runtime, it moves between releases
(Claude's layout changed twice this year), and a wrong guess corrupts someone else's history.

## R4. Making a worktree from inside a worktree

**Finding**:
- `GitWorktrees.repository(of:)` returns `--show-toplevel`. From inside a linked worktree that is
  the *worktree's* top, so `worktreesFolder` would nest `.agents/worktrees/x/.agents/worktrees/y`.
- `GitWorktrees.add(branch:path:in:)` runs `git worktree add -b <branch> <path> HEAD` in the
  folder given.

**Decision**: `makeWorktree` gains a `from:` folder, used for two things:
1. It's the folder the `git worktree add … HEAD` runs in, so HEAD is the agent's current
   checkout.
2. It's where `GitWorktrees.base(in:)` is read, so "merged" is measured against the branch the
   new one came from.

The repository, the worktrees folder, the exclude line and the name reservation still come from
the agent's `projectFolder`, exactly as in 030. `from:` defaults to the project folder, so 030's
callers are unchanged.

## R5. Handing the conversation to a runtime that lost it

**Decision (conditional on Phase 0)**:
- A `Handover` in `ACP/Serve` builds a context block from the app's transcript: the person's
  messages, the agent's replies, and one line per tool call with its target. It's shortened from
  the oldest end to a budget.
- It's sent as a preface on the first prompt of the new session, in the briefing's slot.
- It's used wherever `connect` falls back to `newSession` for an agent that had a session. That
  also improves today's "no longer has this conversation" case.
- 052 FR "the new runtime is given everything the transcript holds" needs the same thing, so it's
  built once, with 052's shortening rule ("a history larger than the new runtime can take is
  shortened").

**Alternatives**: accept the loss and say so. That's the fallback if Alex prefers not to build
Handover in this lane. Phase 0's result goes to him first.

## R6. Where the pending move is applied

**Decision**: `applyPendingMove(agentID)` is called:
- in `finishTurn`, after `releaseRuntime` and **before** the `stops` guard, so a stopped turn
  still moves (spec edge case);
- the same way in `turnFailed`;
- from `askMove` when no turn is in flight and nothing is being sent (`turnTasks[id] == nil`,
  `!sending.contains(id)`, `!state.hasTurnInFlight`);
- from `recover()` for an agent with a `pendingMove` and no turn to pick up. One that 025
  resumes mid-turn applies it when that turn ends.

It runs before `resumeIfCleared`, `askForOutcomeIfSilent` and `drainQueue`. Whatever turn comes
next, whether the app's continue prompt, a queued prompt or a resume, starts in the new folder.

The continue prompt (agent-asked, not stopped) is queued like 039's resume, `from: .app`, only
when the queue is empty. With queued prompts, the person's words go first and the move preface
rides on them.

Archive and delete drop `pendingMove`. A stop doesn't.

## R7. Removing Claude's tools

**Decision**:
- Add `RemovedTool(name: "EnterWorktree")` and `RemovedTool(name: "ExitWorktree")` to
  `ToolPolicyCatalog.claude`, through the existing `disallowedTools` lever.
- They go under a new `RemitCategory.workingFolder`: "changing the folder the session works in".
  None of the existing categories fits, and the briefing and the check script group by category.
- Mirror them in `scripts/runtime-tools.sh`'s copy.
- If Phase 0's tool listing finds an equivalent on Grok, Copilot or Cursor, add it the same way.
  Grok has a `~/.grok/worktrees.db`, so check Grok first.

## R8. What follows the folder, and what doesn't

These read `agent.cwd` when they are used, so they follow a move with no change:
- the Changes pane's daemon side (`DaemonCore+Changes`);
- file mentions;
- serving file reads and writes;
- new shells (`DaemonCore+Shells`);
- the chat subtitle;
- the row's worktree badge (reads `agent.worktree`);
- archive cleanup (`removeWorktreeIfDone` reads `agent.worktree`);
- `listWorktrees` (matches agents by `cwd`).

These need a change:
- **`FilesPane`** starts a `FolderWatch` or server watch on `agent.cwd` when it appears. It
  re-watches on `.onChange(of: agent.cwd)`.
- **An open terminal** keeps its shell. A strip says the agent moved, and offers a new shell in
  the new folder.
- **The Changes pane view** refreshes when `cwd` changes. Checked in Phase 3; it may already key
  on the agent record.

## R9. The person's control

**Decision**: The Worktree capsule from the draft prompt bar (`PromptBar.worktreeChooser`) is
shown on an agent's page too, whenever the agent's project is a repository and the agent is on
this host:
- Its title is where the agent is now.
- Its choices are the same as the draft's plus **Project folder**.
- Choosing sends `agents/move`.
- While a turn runs, the title reads "Moving to <name> when this turn ends", with a Cancel choice.

"New worktree on a branch" (030's `.branch`) is left out of the move for now. It isn't in the
spec, and the agent can check a branch out itself.

**Rejected**: a separate "Move…" sheet. It's a second place for the same choice the capsule
already makes.

## R10. Names

- `enter_worktree` with `name` runs it through `WorktreeName.from(prompt:)`. That keeps
  `fix-login` as it is and turns spaces or slashes into hyphens.
- With neither `name` nor `path`, the agent's `title` is used, then `agent-MMdd-HHmm`.
- The name is chosen and reserved at apply time, not ask time, so two agents moving at once still
  get different names (030 SC-003).
- The tool's answer gives the name it expects to use.
