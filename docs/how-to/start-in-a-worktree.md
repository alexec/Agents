---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Give an agent its own Git worktree and branch, so it can work without touching your project folder.
---

# Start an agent in its own worktree

A worktree is a second checkout of the same repository, on its own branch. An agent in a
worktree can edit, build and commit without getting in the way of you, or of another
agent, in the project folder.

## Before you start

- The project is a Git repository with at least one commit. In a folder that is not a
  repository, the choice below does not appear. See [Add a project](add-a-project.md).

## Steps

1. Open the project's page.

   On iPhone or iPad, open the project and tap **New session**.
2. Before you send the first prompt, open the **Worktree** choice. On the Mac it sits
   above the prompt, beside the folder, and says **Project folder** until you change it.
   On iPhone and iPad it is the **Worktree** row of the start form.
3. Choose where the agent works:
   - **Project folder**: the folder itself, alongside anything else working there. The
     line under it names the branch the folder is on.
   - **New worktree**: *A new branch from the last commit here.* The app makes the
     worktree in `.agents/worktrees/` at the top of the repository, on a new branch under
     `agents/`, both named from the first few words of your prompt.
   - A worktree already listed: join one that exists. The line under each says its
     branch and how many agents are working in it.
   - **New worktree on a branch**: make a worktree on a branch you already have, local
     or from a remote, marked **From** the remote. On the Mac every worktree and every
     branch is listed, and the list scrolls when there are more than fit.
4. Type the prompt and send it.

   The agent starts in the worktree.

**Move an agent that is already working**

An agent that started in the project folder can move into a worktree later, or back out.

1. Open the agent. On the Mac, the choice above the prompt names where it works: the
   branch the project folder is on, or the worktree's name.
2. Open it and choose **New worktree**, a worktree already listed, or **Project folder**.
   - If the agent is between turns, it moves at once. The conversation says where to, and
     how many uncommitted changes stayed behind.
   - If it is working, the choice reads **Moving to …** and the move happens when its turn
     ends. **Cancel move** takes it back until then.
3. Send the next prompt. The agent carries on in the new folder with the whole
   conversation, and the files, changes and row all follow it.

Agents can also move themselves, by naming a worktree when they finish a turn with
`finish_turn` (see [Tools the app gives agents](../reference/agent-tools.md)). An agent that
asks is moved when its turn ends and started again there to carry on.

Nothing uncommitted comes along: a new worktree starts from the last commit of the folder
the agent is leaving, and what was not committed stays where it was.

An agent on Grok, Gemini or Antigravity cannot move: those runtimes can't carry their
conversation into another folder, or haven't been checked. The choice is greyed out and its
tooltip says why. Start a new agent in a worktree instead.

**When the work is done**

1. Have the agent commit what it did, and merge or push the branch the way you usually
   would.
2. Archive the agent. See [Stop, park and archive agents](archive-park-stop.md).

   If the app made the worktree, no other agent is working in it, and everything in it
   is committed, archiving removes the worktree. Its branch is deleted too if it has
   been merged; otherwise the branch is kept, with its commits. The conversation says
   which, for example *Removed the worktree fix-login. Its branch agents/fix-login is
   kept, since everything in it was committed.*
3. A worktree that still has uncommitted changes, or has other agents in it, is left
   where it is. It is listed under **Worktrees** on the project's page (on iPhone and
   iPad too). When you are done with it, archive the agents in it, then click
   **Remove…** beside it. If removing it would lose uncommitted changes or unmerged
   commits, the app says what would be lost and asks first.

   Only worktrees the app made have **Remove…**. Ones you made yourself in Terminal are
   listed but left for you to remove.

On the project's page, **Refresh worktrees** updates the list after changes made outside
the app. **Clean up worktrees** fills a new agent's prompt with a request to remove
worktrees and branches for work already merged into the default branch. Review the
request, then send it when you are ready.

## If it doesn't work

- **New worktree** is greyed out with *There is no commit here yet to base a worktree
  on.* Make a first commit in the project, then try again.
- *… is already checked out in …* means that branch has a worktree already. Choose that
  worktree from the list instead of making a new one.
- **Remove…** is greyed out: an agent is still working in the worktree. Archive it first.
- The terminal says *This shell is in … The agent now works in …*: the agent moved while
  your shell went on in the old folder. The shell is yours and is never stopped for you;
  click **Type cd there** to follow the agent.
- The session's row says **Folder is missing**, and sending to it says *This agent's
  folder isn't there any more (…). It was a worktree, and may have been removed after
  merging.* Its worktree was removed outside the app, for example by `git worktree
  remove` after a merge. What you typed stays in the prompt. Over the chat, and in the
  message, choose one of these:
  - **Continue in the project folder** starts a new session in the project folder on the
    same runtime, with the same name. The new session reads this one and carries on, with
    anything you had typed after that.
  - **Recreate the worktree** makes the worktree again from its branch, in the same
    place. It is offered only while the branch is still there. Send again afterwards.
  - **Archive** puts the session away.

  The same happens to any agent whose folder has been moved or deleted, or is on a disk
  that isn't connected. Recreate the worktree is not offered for those.
