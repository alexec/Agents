---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Watch a document take shape beside the conversation as an agent writes it, and type on it yourself.
---

# Follow a live document

When an agent writes a document for you, such as a plan, a spec, notes or a review, it can
open it beside the conversation. The page fills in as the agent writes, goes to each
change, and marks what changed. You can type on it too. This guide has an agent write a
short plan while you watch.

## Before you start

- An agent on Claude, Grok or Cursor. Copilot conversations do not get the app's tools,
  including the one that opens a page. See [Runtimes](../reference/runtimes.md).
- The document is an ordinary Markdown file inside the agent's project folder or worktree.

## Steps

1. Ask for a document, and ask to see it. For example:

   ```text
   Write a plan for adding dark mode to plan.md, and show it to me while you write it.
   ```

   Agents are told to open a document as soon as they start one, so "show it to me" is
   often not needed.

2. Watch the page. It opens in the files pane beside the conversation, empty at first,
   and fills in as the agent writes. Each time the agent changes the file:

   - the new text appears as if typed, and what changed is marked for a moment,
   - the page scrolls to the change, whether it is at the end or back in the introduction,
   - a flag with the runtime's name, such as **Claude**, shows where it is working.

3. Type on it. Click a passage to edit it, and type. What you type is saved to the file as
   you go; there is nothing to save. If it cannot be saved, the page says **Not saved** and
   why.

4. Send your next prompt. When its next turn starts, the agent is told what you changed on
   the page, so it builds on your words instead of putting its own back.

## If you and the agent change the same passage

If the agent changes a passage while you are typing in it, your text is kept and a card
says **The agent changed this passage while you were typing. Yours is kept; theirs is
below.** Choose **Use theirs** or **Keep mine**.

An edit you finished and left can still be written over if the agent rewrites the whole
file later in the same turn. Type between the agent's turns when you can.

## Pictures and diagrams

Agents draw diagrams and graphs as picture files, usually SVG, beside the document, and
reference them from it. The page shows them in place and redraws one when the agent
changes it. Open a picture on its own to zoom in.

## On the iPhone and iPad

Open the agent's conversation and its files. A live document there follows the agent's
writing and takes your typing in the same way as on the Mac.

## Things to know

- **A page the agent opens asks for you.** Until you have looked, the agent is listed
  under **Needs attention**. See [Statuses and groups](../reference/statuses.md).
- **Any Markdown file can be read this way.** Click one in the files pane to open it as a
  page.
- **Only files the agent can reach.** An agent can open a page only inside the folders it
  was given.

## See also

- [Read an agent's changes](read-an-agents-changes.md), for code rather than documents
- [Tools the app gives agents](../reference/agent-tools.md), for `show_file`
