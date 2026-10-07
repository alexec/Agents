---
diataxis: how-to
devices: [mac]
description: Pick up a conversation a runtime already holds, such as one you started in Terminal, or delete one.
---

# Pick up a conversation started somewhere else

A runtime keeps its own list of conversations, including ones you started in Terminal or
in another app. From a new session you can see what a runtime holds in a folder, pick one
up so it carries on in Agents, or delete one you no longer want.

## Before you start

- A project on this Mac with the runtime you used. See [Add a project](add-a-project.md).
- A runtime that lists its conversations. One that does not says it is holding nothing.

## Steps

1. Unfold the project in the sidebar and click **New session**, the first row under it (or press ⌘N).
2. Above the prompt, choose the runtime you used, such as **Claude**, and the folder the
   conversation was in.
3. Click the clock button beside the runtime (**Conversations this runtime is already
   holding here**).

   A sheet opens, **Conversations in** the folder's name, listing each conversation with
   its title and when it last changed. One already in Agents says **already here**.
4. Click **Pick up** beside the one you want.

   The sheet closes and the conversation opens as an agent in the project, with what was
   said so far. Send a prompt to carry on.
5. Click **Done** to close the sheet without picking anything.

**Delete a conversation**

1. In the same sheet, click the bin beside it.
2. Confirm with **Delete**. This removes it from the runtime as well as from the app, and
   cannot be undone.

To try something else from a conversation without changing it, branch it instead: open it
and choose **Session ▸ Branch** (Option-Command-B). See
[Keyboard shortcuts](../reference/keyboard-shortcuts.md).

## If it doesn't work

- **The runtime is holding nothing here.** The runtime has no conversation in that folder,
  or cannot list its conversations. Check the folder: a conversation belongs to the
  folder it was started in.
- **The clock button is greyed out.** Choose a folder and a runtime first.
