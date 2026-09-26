# Walk: quickstart §3, an agent moves itself (T020)

2026-09-26, scratch root `/tmp/run-m053`, this branch's build at `f9416a2`. One git project per
runtime with one commit. Prompt: "Move into a worktree of your own with enter_worktree, then add a
line 'moved' to README.md and commit it." Permissions answered yes by the walk script.

| Runtime | Called `enter_worktree` | Moved when the turn ended | Picked its session back up | Carried on by itself | Committed in the worktree |
|---------|------------------------|---------------------------|----------------------------|----------------------|---------------------------|
| Claude  | yes (asked permission first) | yes, `readme-edit-worktree` | yes | yes | yes, `986a4f6` on `agents/readme-edit-worktree` |
| Grok    | yes | yes, `moved-readme` | **no**: "Grok no longer has this conversation. Carrying on in a new one" | yes, and worked out what was left from the worktree and the move preface | yes, `f20b91a` on `agents/moved-readme`; then archived itself, and 030's cleanup removed the worktree and kept the branch |
| Cursor  | yes | yes, `readme-moved` | yes | yes | yes, `14de20f` |
| Copilot | **no**: Copilot sessions get none of the app's MCP tools (known since 036, not even `finish_turn`) | — | — | — | made its own worktree with `git worktree add` beside the repository (`../w-copilot-task-worktree`), which the app knows nothing about |

In every case the project folder was left as it was: its only changes were the dotagents layout
files `projects/add` laid out (`.claude/`, `AGENTS.md`, `CLAUDE.md`, untracked), which the move
reported as "3 uncommitted changes stayed in the project folder".

Found and fixed during the walk:
- The tool's answer named "a new worktree like move-into-worktree-your", but the worktree was made
  as `readme-edit-worktree`, because the agent retitled itself in the same turn. The name is now
  settled when the move is asked (`7433990`).
- The Changes pane would have gone on measuring the old folder: `startingPoint.repository` was
  never moved. It is now re-anchored in the new checkout, keeping the commit the agent started on
  when the new checkout's history has it.

Open:
- Grok loses its conversation on every move (research R3). It carried on well here because the
  task was small and the preface says where it is. Whether to build Handover (T027 to T029) is
  Alex's call.
- Copilot cannot move at all until it gets the app's tools, which is outside this feature.
- Claude asks permission before `enter_worktree`, as it does before the lease tools.
