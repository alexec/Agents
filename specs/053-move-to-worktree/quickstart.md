# Quickstart: Proving an Agent Can Move into a Worktree Mid-Work

Everything here runs in a scratch root or temporary repositories, never against the real
daemon.

## 0. Prerequisites

- A build of this branch. Build both schemes one after the other, with plugin validation skipped.
- The four runtimes installed and signed in: Claude, Grok, Copilot, Cursor.
- For §3 and §4, the run-app skill's scratch root (it launches with a clean environment).

## 1. Unit and integration

```sh
cd Packages/AgentsKit
swift test --filter 'AgentMoveRecordTests|MoveToolParsingTests|ToolPolicy|MoveTests|WorktreeStartTests'
```

Expected results:
- `MoveTests` passes each story and edge case in the spec with a real temporary git repository
  and the fake runtime. The fake runtime records the `cwd` of every `session/resume` and
  `session/new`, so "the next start is in the worktree" is asserted directly.
- 030's `WorktreeStartTests` still pass, since `makeWorktree(from:)` defaults to the project
  folder.

## 2. Phase 0: resuming across folders (gate)

```sh
AGENTS_LIVE=1 swift test --filter RuntimeMoveLiveTests
./scripts/runtime-tools.sh
```

For each runtime:
1. A session in folder A is told a word.
2. The process ends.
3. A new process in folder B continues the session and is asked for the word.

Record in research R2 and R3 which runtimes remember it. Also record any worktree-moving tool
that `runtime-tools.sh` lists for a runtime other than Claude.

## 3. A real agent moves itself (per runtime)

On the scratch root, in a git project with one commit:
1. Start an agent in the project folder: "Move into a worktree of your own, then add a line to
   README.md and commit it."
2. The agent calls `enter_worktree` and ends its turn.

Expected:
- `.agents/worktrees/<name>` and the branch `agents/<name>` exist.
- The chat shows the "will move" line, then the "Moved …" line.
- A new turn starts by itself.
- `git -C <project> status` is clean, and README's change is committed on `agents/<name>` in the
  worktree.
- The row shows the worktree badge.
- Restart the scratch app: the agent resumes in the worktree (the fake-free version of US2 §1).
- For a runtime that kept its session in §2, ask it what it was first asked. It knows.

Then ask it to "go back to the project folder and remove the worktree". It calls `exit_worktree`
with `remove`:
- With everything committed, the worktree goes and the branch stays, because it isn't merged.
  The chat says so.
- With an uncommitted edit, it's refused and the files are listed.

## 4. Mac walk (run-app skill)

1. Open an idle agent in the project folder. The prompt bar shows **Worktree: Project folder**.
   Screenshot it.
2. Choose New worktree. It moves at once, and the capsule reads the worktree's name. The files
   pane shows the worktree. No turn starts. Screenshot it.
3. Send a prompt that takes a while. While it runs, choose Project folder. The capsule reads
   "Moving to Project folder…". Choose Cancel move, and the waiting move is gone. Choose it
   again and let the turn end: the agent is back in the project folder. Screenshot it.
4. With a terminal open before the move, check that the strip appears and that its button opens
   a shell in the new folder.
5. On a Claude agent, ask "do you have EnterWorktree?". It doesn't, and names `enter_worktree`.

## 5. Phone look (Alex's)

Open a moved agent on the iPhone. The row badge shows the worktree, and the chat shows the move
lines.
