---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Stop an agent mid-turn, or archive a chat when you are done, including one that asks to be archived.
---

# Stop and archive agents

Two ways to put an agent down, each keeping its whole conversation:

- **Stop** ends what it is doing now. The chat stays where it is, and you can tell it what
  to do next.
- **Archive** puts away a chat you are done with. It folds out of sight under **Archived sessions**.
  It can be unarchived.

An agent that has finished can also archive itself. A chat you started does so without asking, unless you turn that off; where it needs your approval, you approve it with one click.

## Before you start

- An agent to put down. See the [tutorials](../tutorials/index.md) to start one.

## Steps

**Stop an agent**

1. Open its conversation and click **Stop** above the prompt, or press **⌘.** (Command
   and full stop). On iPhone and iPad, tap **Stop** in the bar at the top.

   On the folder's page you can also right-click the agent's card and choose **Stop**.
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
   bottom of the folder's page, folded away.
2. If the agent worked in a worktree the app made, and everything there is committed,
   archiving also removes the worktree. See
   [Start an agent in its own worktree](start-in-a-worktree.md).
3. To unarchive it, open **Archived**, then right-click the card and choose **Unarchive**.
   On iPhone and iPad, open **Archived**, open the chat, and choose **Unarchive** from
   the **Actions** menu.

**Approve archiving a chat**

An agent that thinks its work is finished archives its chat with `archive_session`. Where
that needs your approval, and its turn ends **Complete**, **Nothing to do** or **Partly
done**, the chat carries an **Archiving needs approval** mark on its row, as the unread
mark is. It stays in its group, usually **Done**; a
partly done one stays under **Needs you**. Nothing is hidden until you approve it.

1. Open the chat. At the end of the conversation, a card in orange says **The agent asks
   to archive this session**, with what the agent said last. Click **Approve** to archive
   it, or **Keep Session** to keep it. The card is the same on the Mac, iPhone, iPad and the
   web page. When you are scrolled up, **↓** takes you back to it at the end.
2. Or use **Needs You**, at the top of the sidebar. It shows every chat waiting for
   approval, in every folder and on every host. **Approve** is beside the mark on the
   Mac's row; on the Remote and the web page it is in the row's menu and its swipe. Each
   row is approved on its own; there is no button that archives them all.
3. To keep the chat instead, send it a prompt. That drops it. So does a later turn
   that ends wanting you: with a question, stuck, blocked or crashed. Unarchiving an
   archived chat does not bring the mark back.

A chat you started, a workflow's run whose workflow allows it to archive itself, and a
helper in a folder where agents may archive their helpers, are archived without your
approval, if the turn ends **Complete** or **Nothing to do**. A partly done one still waits
for it.

For chats you started, this is the setting **Agents may archive the chats I start**, in
**Settings ▸ This app ▸ Sidebar ▸ Finished chats** on the Mac, iPhone and iPad, and
**Settings ▸ This browser ▸ Finished chats** on the web page. It is kept on your Mac, so it is the same on every
client. It is on at first. Turn it off to approve each one, as
above. Even with it on, a chat whose last turn showed you a file with `show_file` is not
archived: it stays unread under **Done**, with the file's mark on its row, and asks no
approval. Bring back an archived chat with **Unarchive**. See
[When a run is done](../reference/workflows.md#when-a-run-is-done) and
**Agents may archive the helpers they started** in the
[settings reference](../reference/settings.md).

**Undo Archive**

Each time you archive, the app gives you five seconds to take it back. This lets you
undo an archive by mistake without a search under **Archived**.

1. Archive a chat. A strip shows **Archived** and the chat's title, for example
   **Archived “Fix the parser”**, with **Undo**. On the Mac and the web page it is at the
   foot of the sidebar. On iPhone and iPad it is at the foot of the screen.
2. Click **Undo** in the strip within five seconds. Or use the keyboard:
   - On the Mac, choose **Session ▸ Undo Archive**, or press **⌘Z**. The menu item is
     there only while the strip shows. For those five seconds, **⌘Z** undoes the archive
     even in a text field.
   - On an iPad with a keyboard, press **⌘Z** while the strip shows.
   - On the web page, press **⌘Z** or Ctrl+Z while the strip shows. In a text field,
     **⌘Z** stays the field's own undo.
3. The chat comes back where it was. The chats it started, which Archive put away with
   it, come back too.

Undo is the same as **Unarchive**. It does not start an agent again: if the agent was
working, Archive stopped it, and it stays stopped. The strip then says so, for example
**Archived “Fix the parser” and stopped it. Undo does not start it again.**

On the Mac, when you select more than one session and press Delete, one strip covers
all of them, for example **Archived 3 sessions** or **Archived 2 sessions and 1
workflow**. **Undo** brings all of them back. The Remote and the web page archive one
chat at a time.

The five seconds wait while the pointer is on the strip, so you have time to read it. On
the Mac, iPhone and iPad they also wait while VoiceOver is on, and VoiceOver reads the
strip when it comes. On the web page they also wait while the strip has the keyboard
focus, and a screen reader reads the strip when it comes. After the five seconds, use
**Unarchive**, as above.

**What each keeps**

| | Stop | Archive |
|---|---|---|
| Conversation, cost, settings and labels | Kept | Kept |
| Where it is listed | **Stopped** | **Archived sessions**, folded away |
| Asks for your attention | No | Never |
| Worktree | Kept | Removed if everything in it is committed |
| Afterwards | | Deleted after 30 days, or now with **Delete…** |
| Comes back by | Sending a prompt | **Unarchive** |

## Deleting archived chats

An archived chat, including its labels and their owners, is kept whole and can be unarchived or branched from for **30 days**.
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
- To keep a chat, unarchive it.
- To change how long, or to keep archived chats until you delete them, see **Settings ▸
  General ▸ Archived agents** in the [settings reference](../reference/settings.md).

Deleting removes only what Agents keeps. It never touches your files, your commits, or the
runtime's own copy of the conversation.

To put a whole folder away, see [Add a folder](add-a-folder.md).
