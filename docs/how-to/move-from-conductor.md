---
diataxis: how-to
devices: [mac, web]
description: Bring your Conductor workspaces and their Claude Code and Codex conversations into Agents, and carry on where you stopped.
---

# Move from Conductor to Agents

Conductor keeps each workspace as a Git worktree of your repository, and runs Claude Code
or Codex in it. Agents finds the worktrees of a folder's repository, and the conversations
that a runtime keeps in each of them. So you do not copy anything: you add the repository
as a folder, and pick up each conversation. The agent keeps what it knew, because the
runtime resumes its own conversation.

## Before you start

- Conductor's workspaces still on disk. A workspace that Conductor archived or deleted is
  no longer a worktree, and its conversations are not listed.
- The runtime that the workspace used, Claude Code or Codex, set up in Agents. See
  [Choose a runtime, model and mode](choose-runtime-model-mode.md).

## Steps

1. Add the repository's main checkout as a folder, not a Conductor workspace. See
   [Add a folder](add-a-folder.md).

   The folder's worktrees now include each Conductor workspace, by its name. To see them,
   open the **Worktree** choice above the prompt. See
   [Start an agent in its own worktree](start-in-a-worktree.md).
2. Click **New session** under the folder, and choose the runtime the workspace used,
   such as **Claude**.
3. Click the clock button beside the runtime (**↺** on the web page).

   The sheet lists the conversations that the runtime keeps in the folder and in each of
   its worktrees. One in a Conductor workspace says **in** and the workspace's name.
4. Click **Pick up** beside a conversation.

   It opens as a session in the folder, with what was said so far, working in the same
   workspace. Send a prompt to carry on.
5. Do steps 2 to 4 again for each conversation you want, and for the other runtime.

To start new work in a Conductor workspace, choose it in the **Worktree** choice before
you send the first prompt.

## If it doesn't work

- **The runtime is holding nothing here.** Check that you added the main checkout, and
  that the workspace is still a worktree: in Terminal, `git worktree list` in the folder
  lists each one.
- **A conversation shows under the workspace as a folder of its own.** You added the
  workspace, not the main checkout. Add the main checkout and pick the conversation up
  from there.

See also [Pick up a conversation started somewhere else](pick-up-a-conversation.md).
