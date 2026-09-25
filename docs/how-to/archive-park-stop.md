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
- **Archive** puts away a chat you are done with. It folds out of sight, and can be
  brought back.

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
3. To bring it back, open **Archived** on the project's page, then right-click the card
   and choose **Bring back**. On iPhone and iPad, open it and choose **Bring back** from
   the **Actions** menu.

**What each keeps**

| | Stop | Park | Archive |
|---|---|---|---|
| Conversation, cost and settings | Kept | Kept | Kept |
| Where it is listed | **Stopped** | **Parked** | **Archived**, folded away |
| Asks for your attention | No | Never | Never |
| Worktree | Kept | Kept | Removed if everything in it is committed |
| Comes back by | Sending a prompt | Sending a prompt, or **Unpark** | **Bring back** |

To put a whole project away, see [Add a project](add-a-project.md).
