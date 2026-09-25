---
diataxis: how-to
devices: [mac, iphone, ipad]
description: See what an agent changed, file by file and edit by edit, in the Changes pane, the conversation and the files pane.
---

# Read an agent's changes

When an agent has been working, you want to know what it changed, all together, and
whether it is right. The **Changes** pane lists every file it changed and what changed in
each. The conversation shows each edit where it happened.

## Before you start

- An agent that has changed something. See the [tutorials](../tutorials/index.md).

## Steps

**See everything it changed (Mac)**

1. Open the agent's conversation. If the sidebar on the right is closed, open it with the
   sidebar button at the top right of the window.
2. Click **Changes** at the top of the sidebar (beside **Files**, **Terminal**,
   **Browser** and **Exchanged**).

   The files it changed are listed, grouped by folder, each with the lines added and
   removed (**+12 −3**). Until it changes something, the pane says **Nothing changed
   yet**.
3. Click a file. Its changes are shown with added and removed lines marked and the
   words that changed within a line highlighted. Unchanged stretches are folded into a
   line such as **14 unchanged lines**; click it to open them.
4. Move between changes with the up and down arrows at the top (**Previous change** and
   **Next change**). The left arrow (**All changed files**) goes back to the list.
5. To read the change in context, switch from **Edits** to **Whole file**. The whole file
   is shown as it is now, with the changed lines marked. **Open in Files** opens it in the
   **Files** pane.

If the agent works in a folder it shares with you or other agents, a note at the top of
the list says that it also shows what git sees changed there, which may include other
work than this agent's. An agent in its own worktree has no such note; see
[Start an agent in its own worktree](start-in-a-worktree.md).

**See each edit where it happened**

1. In the conversation, each edit the agent makes appears as it makes it, under the step
   that made it, with the lines before and after.
2. Click **Show in Changes** under an edit to jump to it in the **Changes** pane, among
   everything else the agent changed.

**Browse the folder (Mac)**

Click **Files** in the sidebar to browse the agent's folder. Files the agent changed are
marked. Click one to read it; code is shown with its syntax coloured, and pictures and
Markdown are shown as they look.

**On iPhone and iPad**

1. In the conversation, each edit is shown where it happened, as on the Mac.
2. Open **Files** from the conversation to browse the agent's folder on the Mac and read a
   file.
3. With a changed file open, tap **What the agent did** to see its edits in this
   conversation, newest first.

## If it doesn't work

- **Nothing to show**, saying the runtime hasn't reported any edits: some runtimes, such
  as Grok, do not say what they edit, and the folder is not one git can compare. Changes
  made by commands rather than edits cannot be shown either. Use the **Terminal** pane and
  `git diff` instead.
- **This file has changed since the agent's last edit, in ways it didn't report.**
  Something else changed the file afterwards. Click **See the whole file** to read it as
  it is now.
- A very large change says how many lines changed instead of drawing them. Click **Show
  changes** to draw it anyway.
