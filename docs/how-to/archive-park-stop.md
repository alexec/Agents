---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Stop an agent mid-turn, park a chat to come back to later, or archive it when you are done.
---

# Stop, park and archive agents

Three ways to put an agent down, each keeping its whole conversation:

- **Stop** ends what it is doing now. The chat stays where it is, and you can tell it what
  to do next.
- **Park** puts a chat you have finished with *for now* in its own group, to come back to.
- **Archive** puts away a chat you are done with. It folds out of sight under **Archived**.
  Any of them can be brought back.

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

**Park a chat**

1. Open the conversation and click **Park**, between **Stop** and **Archive**. On iPhone
   and iPad, tap the **Actions** menu (**…**) at the top and choose **Park**. On the
   project's page you can also right-click the card and choose **Park**.

   You go back to the project. The chat is under **Parked**, below **Stopped**, with when
   you parked it. It does not ask for your attention while it is there, and it never
   comes back by itself.
2. If the agent is still working, it finishes the turn first. Its card says **Parks when
   this turn ends**.
3. To come back to it, open it and send a prompt; that unparks it. Or click **Unpark** to
   put it back where it was without saying anything.

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

**What each keeps**

| | Stop | Park | Archive |
|---|---|---|---|
| Conversation, cost and settings | Kept | Kept | Kept |
| Where it is listed | **Stopped** | **Parked** | **Archived**, folded away |
| Asks for your attention | No | Never | Never |
| Worktree | Kept | Kept | Removed if everything in it is committed |
| Afterwards | | | Retired after 30 days, or sooner when archived agents take more than 2 GB |
| Comes back by | Sending a prompt | Sending a prompt, or **Unpark** | **Bring Back** |

## How long archived chats are kept

An archived chat is kept whole, and can be brought back or branched from, for **30 days**.
After that it is **retired**: its conversation is deleted, and a short record of who the agent
was is kept, so an event or a chat that names it still says who it was. Archived chats may also
take up to **2 GB** between them; past that, the ones archived longest ago are retired first.

- Nothing is retired on the day it was archived, so an archive by mistake can always be undone.
- A chat whose worktree still has changes that are not committed or merged is kept until they
  are, and its card says so. So is one a workflow run still belongs to, or one you have open.
- A few days before a chat is retired, its card under **Archived** says **Retires in 3 days**.
  The list ends with how many older chats have been retired.
- To keep a chat, bring it back, or park it instead of archiving it. Only archived chats are
  ever retired.
- To retire one now, right-click its card under **Archived** and choose **Retire Now…**.
- To change how long and how much, or to keep archived chats forever, see **Settings ▸ General ▸
  Archived agents** in the [settings reference](../reference/settings.md).

Retiring deletes only what Agents keeps. It never touches your files, your commits, or the
runtime's own copy of the conversation.

To put a whole project away, see [Add a project](add-a-project.md).
