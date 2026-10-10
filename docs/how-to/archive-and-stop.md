---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Stop an agent mid-turn, or archive a chat when you are done, including one that asks to be archived.
---

# Stop and archive agents

Two ways to put an agent down, each keeping its whole conversation:

- **Stop** ends what it is doing now. The chat stays where it is, and you can tell it what
  to do next.
- **Archive** puts away a chat you are done with. It folds out of sight under **Archived sessions**.
  It can be brought back.

An agent that has finished can also ask you to archive it. You agree with one click.

## Before you start

- An agent to put down. See the [tutorials](../tutorials/index.md) to start one.

## Steps

**Stop an agent**

1. Open its conversation and click **Stop** above the prompt, or press **⌘.** (Command
   and full stop). On iPhone and iPad, tap **Stop** in the bar at the top.

   On the project's page you can also right-click the agent's card and choose **Stop**.
2. The turn ends where it is, any question it was waiting on is cancelled, and the agent
   moves to **Stopped**. The conversation stays open, so you can read what it did.
3. To carry on, type a prompt and send it. The agent picks up with the whole conversation
   so far.

**Archive a chat**

1. Open the conversation and click **Archive** (on iPhone and iPad, **Archive** in the
   bar at the top). Or, on the Mac, swipe the agent's card to the left with two fingers
   on the trackpad and click the **Archive** button it uncovers; or right-click the card
   and choose **Archive**.

   An agent still working is stopped first. The chat moves under **Archived** at the
   bottom of the project's page, folded away.
2. If the agent worked in a worktree the app made, and everything there is committed,
   archiving also removes the worktree. See
   [Start an agent in its own worktree](start-in-a-worktree.md).
3. To bring it back, open **Archived**, then right-click the card and choose **Bring Back**.
   On iPhone and iPad, open **Archived**, open the chat, and choose **Bring Back** from
   the **Actions** menu.

**Archive a chat that asks to be archived**

An agent that thinks its work is finished can ask to be archived. If its turn ends
**Complete**, **Nothing to do** or **Partly done**, the chat carries an **Asks to archive**
mark on its row, as the unread mark is. It stays in its group, usually **Done**; a
partly done one stays under **Needs you**. Nothing is hidden until you archive it.

1. Click **Archive** beside the mark on the Mac's row, or in the strip over the chat. On
   iPhone, iPad and the web page, the strip over the chat has **Archive** too, and so do
   the row's menu and its swipe.
2. Or open **To Archive**, at the top of the sidebar. It gathers every chat that asks, in
   every project and on every host, and is shown only when one does. **Archive All** in its
   heading archives them all (on the Mac, it is also in the heading's right-click menu).
3. To keep the chat instead, send it a prompt. That drops the request. So does a later turn
   that ends wanting you: with a question, stuck, blocked or crashed. Bringing back an
   archived chat does not bring the request back.

A workflow's run whose workflow allows it to archive itself, and a helper in a project
where agents may archive their helpers, are archived without asking you, if the turn ends
**Complete** or **Nothing to do**. A partly done one still asks you. See
[When a run is done](../reference/workflows.md#when-a-run-is-done) and
**Agents may archive the helpers they started** in the
[settings reference](../reference/settings.md).

**What each keeps**

| | Stop | Archive |
|---|---|---|
| Conversation, cost, settings and labels | Kept | Kept |
| Where it is listed | **Stopped** | **Archived sessions**, folded away |
| Asks for your attention | No | Never |
| Worktree | Kept | Removed if everything in it is committed |
| Afterwards | | Deleted after 30 days, or now with **Delete…** |
| Comes back by | Sending a prompt | **Bring Back** |

## Deleting archived chats

An archived chat, including its labels and their owners, is kept whole and can be brought back or branched from for **30 days**.
After that it is **deleted**: its conversation and record are removed, and nothing is left of
it. An event or a chat that named it just says "another agent".

- To delete one now, right-click its card under **Archived** and choose **Delete…**. On iPhone
  and iPad, touch and hold its card; on the web page, use its **···** menu. You are asked
  first, and it cannot be undone.
- Only archived chats can be deleted. Archive a chat first to delete it.
- Nothing is deleted by age on the day it was archived, so an archive by mistake can always be
  undone.
- A chat whose worktree still has changes that are not committed or merged is kept until they
  are, and **Delete…** says why it cannot go yet. So is one a workflow run still belongs to.
  One you have open is kept from the 30 days, but **Delete…** still works on it.
- To keep a chat, bring it back.
- To change how long, or to keep archived chats until you delete them, see **Settings ▸
  General ▸ Archived agents** in the [settings reference](../reference/settings.md).

Deleting removes only what Agents keeps. It never touches your files, your commits, or the
runtime's own copy of the conversation.

To put a whole project away, see [Add a project](add-a-project.md).
