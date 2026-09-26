# Implementation Plan: An Agent Can Move into a Worktree Mid-Work

**Branch**: `agents/053-move-to-worktree` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/053-move-to-worktree/spec.md`

## Summary

A move is small because the daemon already restarts runtimes. `finishTurn` lets the runtime go
at the end of every turn (`releaseRuntime`, `DaemonCore+Commands.swift`). The next turn starts a
fresh process in `agent.cwd` and asks it to pick up its own session with that folder
(`liveSession` → `connect` → `continueSession(id:cwd:)`). So moving an agent means doing this
between those two moments:
1. Make or check the target with 030's code.
2. Rewrite `agent.cwd` and `agent.worktree`.

The next start happens in the new folder by itself. No new restart path is needed (research R1).

What gets built:
- **Two app tools**, `enter_worktree` and `exit_worktree`, with the same shape as Claude Code's
  own (spec clarification). They are relayed by `agentsd mcp` to a new daemon method,
  `agents/moveSelf`.
- **One person method**, `agents/move`, with a `cancel` form, for the Mac's agent page.
- **A pending move on the record.** Every request is checked at once and stored as
  `Agent.pendingMove`, then applied:
  - at the end of the turn, in `finishTurn` and `turnFailed`, after the runtime is let go and
    before the stop guard;
  - straight away, if no turn is in flight.
- **After an agent's own move**, one app prompt is queued so it carries on. After the person's,
  a one-shot preface tells the agent at its next turn.
- **Making a worktree from inside a worktree.** `makeWorktree` gains a `from:` folder, so the new
  one starts from the agent's current checkout. It is still placed in the *project's* repository
  folder (R4).
- **Claude's `EnterWorktree` and `ExitWorktree` are denied** through `ToolPolicyCatalog`, under a
  new remit category (R7).
- **Mac UI.** The prompt bar's Worktree capsule, today only on a draft, also shows on an agent's
  page. It names where the agent is, and choosing from it moves the agent. The files pane
  re-watches when `cwd` changes.

The one real unknown is whether each runtime can pick up its session from a different folder.
Checked for Claude's CLI: yes (R2). Grok and Cursor file their sessions by folder, so they may
not (R3). Phase 0 is a live check of all four through their ACP adapters, and it is a gate. Any
runtime that loses its session is handed the conversation from the app's transcript. That
handover is the piece 052 needs too, and is built so that 052 can use it (R5).

See [research.md](research.md), [data-model.md](data-model.md) and
[contracts/move.md](contracts/move.md).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**:
- AgentsKit / AgentsKitCore (in-repo package).
- The person's own `git`, through `GitProcess` and `GitWorktrees` (027, 030).
- ACP runtimes over stdio.
- `agentsd mcp` as the app-tool server (023, 028).

**Storage**: One optional field on the agent record, `pendingMove`. `cwd` and `worktree` already
exist and simply change. Nothing else is written, and the worktrees are git's.

**Testing**:
- swift-testing in `Packages/AgentsKit`: Unit tests, plus Integration tests with a fake runtime
  and real temporary git repositories (as in `WorktreeStartTests`).
- One Live test per runtime for resuming across folders (Phase 0), with `AGENTS_LIVE=1`.
- xcodebuild for both schemes, run one after the other with plugin validation skipped.
- The run-app skill on a scratch root for the Mac walk.

**Target Platform**: The macOS app and `agentsd`, including the Linux `agentsd` on servers (037),
since it runs the same `DaemonCore`. The iOS Remote only shows the result: the row badge and the
chat line.

**Project Type**: Desktop app with a daemon, plus a companion iOS app

**Performance Goals**:
- A move adds git's checkout time for a new worktree. Nothing more: the runtime restart is the
  one every turn already has (SC-005).
- No polling. The move runs on the turn's end.

**Constraints**:
- A move never happens mid-turn.
- Nothing uncommitted is ever carried, changed or lost (FR-009, SC-004).
- Old records and old phone builds still decode, because `pendingMove` is optional and ignored
  when not known.
- No new failure codes: the 030 codes cover every refusal. That avoids clashes with other lanes'
  numbers.

**Scale/Scope**:
- One daemon extension, two model types and one record field.
- Two tools, two daemon methods and one relay.
- One tool-policy entry.
- One capsule reused on the agent page, one file-pane fix and one terminal strip.
- The handover only if Phase 0 needs it.

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no formal gates.
The repo's working rules apply:
- **Settle the UX before depth.** Phase 3 puts the capsule on the agent page against a daemon that
  can already move. It is screenshotted with the run-app skill and settled with Alex before the
  terminal strip and the removal wording.
- **One path, not two.** The move reuses 030's `prepareWorktree`, `removeWorktree` and the
  existing turn-end runtime release and next-turn start. The agent's tool and the person's
  control write the same `pendingMove`, and one function applies it.
- **Prove it running.** Phase 0 checks the four real runtimes. Quickstart §3 moves a real agent
  on each, and §4 walks the Mac on a scratch root.
- **Never mutate source to prove a test.** Tests assert the property directly.

Re-checked after design: no violations.

## Project Structure

### Documentation (this feature)

```text
specs/053-move-to-worktree/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── move.md
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/AgentMove.swift              # NEW: MoveTarget, PendingMove, MoveAsker
├── Model/Agent.swift                  # pendingMove field (decodeIfPresent), init
├── Model/AppTool.swift                # enterWorktree, exitWorktree names
├── Runtimes/ToolPolicy.swift          # RemitCategory.workingFolder
├── Runtimes/ToolPolicyCatalog.swift   # Claude: EnterWorktree, ExitWorktree removed
└── Daemon/DaemonAPI.swift             # agents/move, agents/moveSelf; MoveRequest, MoveSelfRequest, MoveAnswer
    Daemon/ConnectionRole.swift        # classify agents/move like agents/stop; moveSelf token-only

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/AppService.swift         # two tool schemas, MoveCall parsing, MovesSink
├── ACP/Serve/Handover.swift           # NEW, only if Phase 0 needs it: transcript → first-prompt context (shared with 052)
└── Daemon/
    ├── DaemonCore+Moves.swift         # NEW: askMove (check + store), applyPendingMove, cancel, notes, preface, auto-continue
    ├── DaemonCore+Worktrees.swift     # makeWorktree(from:), name from a given name or the title, removal excluding the mover
    ├── DaemonCore+Commands.swift      # finishTurn/turnFailed call applyPendingMove; beginTurn takes the move preface; archive drops pendingMove
    ├── DaemonCore.swift               # recover(): apply a pendingMove of an agent with no turn in flight
    └── DaemonCore+Dispatch.swift      # two cases

Daemon/Sources/main.swift              # relay moves: → agents/moveSelf

App/Sources/
├── AppModel.swift                     # agent-page worktree list + move/cancel calls
├── Chat/PromptBar.swift               # Worktree capsule on an agent page: current place, move, "moves when the turn ends", Cancel
├── Sidebar/FilesPane.swift            # re-watch on agent.cwd change
└── Sidebar/TerminalPane.swift (or wherever the shell view lives)  # strip: "the agent now works in …" + open a shell there

scripts/runtime-tools.sh               # its copy of Claude's removed list gains the two names

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/AgentMoveRecordTests.swift        # NEW: round trip; old record decodes; pendingMove ignored by old shape
├── Unit/MoveToolParsingTests.swift        # NEW: name/path exclusive, action required, discard only with remove
├── Unit/ToolPolicyTests (existing)        # the two names removed for Claude
├── Integration/MoveTests.swift            # NEW: real git + fake runtime: every story and edge case
└── Live/RuntimeMoveLiveTests.swift        # NEW: Phase 0, resume across folders per runtime
```

**Structure Decision**: The existing layout, with two new source files (`AgentMove.swift` beside
`AgentWorktree.swift`, and `DaemonCore+Moves.swift` beside `DaemonCore+Worktrees.swift`), plus
`Handover.swift` if Phase 0 calls for it.

## Phases (for /speckit-tasks)

0. **Spike: resuming in another folder (gate).**
   - `RuntimeMoveLiveTests`, per runtime:
     1. Start a session in folder A and have it remember a word.
     2. End the process.
     3. Launch in folder B and call `continueSession(id:cwd: B)`.
     4. Ask for the word.
   - Run `scripts/runtime-tools.sh` and note any worktree-moving tool that Grok, Copilot or
     Cursor offer.
   - Write the results into research R2/R3. If every runtime keeps its session, drop Phase 4.
     Otherwise take the result to Alex before Phase 4.
1. **Record, names and policy.**
   - `AgentMove.swift`, `Agent.pendingMove` and `AppTool` names.
   - `RemitCategory.workingFolder`, Claude's two removals, and the script copy.
   - Unit tests. No behaviour yet.
2. **Daemon: move (US1 + US2, P1).**
   - `DaemonCore+Moves` and `makeWorktree(from:)`.
   - The hooks in `finishTurn` and `turnFailed`, `recover`, and archive dropping a pending move.
   - The chat line, the preface and the auto-continue prompt.
   - `agents/moveSelf`, the two tools and the `main.swift` relay.
   - `MoveTests` covering US1, US2 and the edge cases.
   - **Then quickstart §3 on all four runtimes.** An agent moves itself and carries on.
3. **Mac UI (US3, P2).**
   - `agents/move` and cancel.
   - The capsule on the agent page, with its waiting state and Cancel.
   - The files pane re-watching.
   - Run-app screenshots of the capsule idle, waiting and after a move. **Settle this with Alex
     before going further.** Then the terminal strip.
4. **Handover (only if Phase 0 found a runtime that loses its session).**
   - `Handover` builds the first-prompt context from the transcript, used on the existing "no
     longer has this conversation" fallback.
   - Shaped to 052's FR on carrying history, so 052 reuses it.
5. **One way to move (US4) and proof.**
   - Check that a live Claude agent has no `EnterWorktree`.
   - The phone shows the moved agent's badge and chat line.
   - Both schemes build.
   - Quickstart §4 with screenshots.

## Risks

- **A runtime that cannot pick up its session in the new folder** (R3). The agent would still
  carry on, but the runtime would have lost its memory of the conversation. That's the whole
  point lost. Mitigations:
  - Phase 0 finds out before any UI is built.
  - The handover (Phase 4) gives such a runtime the conversation back from the app's record.
  - Copying a runtime's session file into its new folder's key is rejected (R3): it's private
    storage, and it changes with every release.
- **The agent keeps editing after asking.** Its edits land in the old folder until the turn ends.
  The tool's answer says so, and asks the agent to finish its turn now. Edits made after asking
  are uncommitted work in the old folder, so they stay behind (FR-009). If the agent also asked
  to remove the old worktree, that removal is refused at apply time and the chat line says why.
- **Two tools with nearly the same name.** Claude would show both `EnterWorktree` and
  `mcp__agents__enter_worktree` if the removal failed. The policy test and US4's live check
  guard against that.
- **Claude files the session under the old folder.** Claude's store keeps the session under the
  folder it started in. The runtime-sessions list (030 FR-015) therefore keeps showing it there.
  Picking it back up works regardless (R2). This is noted and not fixed.
- **The terminal.** A shell already open stays in the old folder, because killing someone's
  running process is worse than a stale prompt. New shells open in the new folder, and the strip
  offers one (R8).

## Complexity Tracking

None. No constitution gates, and nothing beyond what the spec asks for. The one conditional piece
(Handover) is decided by Phase 0's measurement, not assumed.
