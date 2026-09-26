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

   On iPhone or iPad, open the project and tap **New agent**.
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
     or from a remote. On the Mac, with more than six branches, type in **Find a branch**
     to narrow the list.
4. Type the prompt and send it.

   The agent starts in the worktree. The choice is made once: an agent stays where it
   started.

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

## If it doesn't work

- **New worktree** is greyed out with *There is no commit here yet to base a worktree
  on.* Make a first commit in the project, then try again.
- *… is already checked out in …* means that branch has a worktree already. Choose that
  worktree from the list instead of making a new one.
- **Remove…** is greyed out: an agent is still working in the worktree. Archive it first.
