---
diataxis: reference
devices: [mac, iphone, ipad, web]
description: Every step of the Get started card and every achievement, when each is ticked, where each shows, and how to hide it.
---

# The Get started checklist

Agents has two checklists for a newcomer. The **Get started** card, on the Mac only,
takes you from a fresh install to your first agent. The **Achievements** list, on every
client, names the next main things to try. Both tick each item from what is really so,
never from a box you tick yourself. Thus a tick always means the step is done.

## The Get started card

The card is at the top of the Mac sidebar. Its heading is **Get started**, with a count
such as **2 of 5**. Each step has a tick or an open circle. A step that is not done shows
one grey line that says what it is, and a button that does it.

| Step | Ticked when | Button |
| --- | --- | --- |
| **Set up Agents on this Mac** | This window is paired with a control plane. Before that, the window shows only its first open, so on the card this step is always ticked. | None |
| **Install an agent runtime** | A runtime on this Mac is installed and is not known to be signed out. A runtime is known to be signed out only after a call to it is refused. | **Install**: opens the **Install your agents** sheet. |
| **Add a folder** | The window has a folder. | **Add Folder…** |
| **Start your first agent** | An agent has run a turn to its end. | **New Agent**: opens the new session page of the folder you last started in, ready to type. It is dimmed until there is a folder. |
| **Pair a phone or browser** | An iPhone, an iPad or a browser is paired. Another Mac window does not count. This step is optional. | **Pair a Device…** |

While the card shows, the **Install your agents** sheet does not open by itself. The
card's **Install** button is the way in.

### When the card shows and goes

- It shows on a new set-up, until every step is done.
- It goes when all five steps are done. Then it does not come back.
- Someone already set up at the first look never sees it. Set up means the four steps
  that are not optional are done.
- The Mac keeps the card's state for each set-up. A scratch copy of the app keeps its
  own.

### Hide it

Click **×** at the top right of the card (**Dismiss Get started**). The card goes and
does not come back. The **Install your agents** sheet then does not open by itself
until the next launch.

The iPhone, iPad and web page have no Get started card. Their checklist is the
**Achievements** list.

## Achievements

An achievement is a first step in Agents. The host awards it the first time you do it, and
keeps it with its date in `achievements.json`. Every client reads the same file, so they
all show the same list. The achievements you have not earned yet are the checklist.

| Achievement | How to earn it |
| --- | --- |
| **First agent started** | Start an agent and let it run a turn. |
| **First phone or browser paired** | Pair a phone or a browser with **Pair a Device…**. |
| **First question answered away from the Mac** | Answer an agent's question from the Remote or the web page. |
| **First workflow made** | Make a workflow that runs an agent on a schedule or an event. |
| **First cloud host started** | Start a machine on a cloud provider. |
| **First pull request landed with nobody watching** | Let an agent open a pull request that merges by itself. |
| **Five agents working at once** | Have five agents in a turn at the same time. |

### When an achievement is ticked

The host ticks an achievement from the records it already keeps. On its first run it looks
back, so steps you took before are ticked with their own date.

- **First agent started**: the first agent that has run a turn to its end.
- **First workflow made**: a folder has a workflow that runs on this host.
- **Five agents working at once**: the first day five or more agents were in a turn at
  the same time.
- **First pull request landed with nobody watching**: the first day in the host's record
  with a merged pull request from an `agents/` branch. This version of the host does not
  count merged pull requests, so it ticks this one only from a day an earlier version
  recorded.

In this version, the host does not tick **First phone or browser paired**, **First
question answered away from the Mac** or **First cloud host started**. They stay on the
list with how to earn them.

### Where the list shows

| Client | Where |
| --- | --- |
| Mac | The **Multiplier** page (**View ▸ Multiplier**, ⌘0), under its numbers. |
| iPhone and iPad | The **Achievements** row in the **Usage** group of the sidebar. |
| Web page | The **Achievements** row in the **Usage** group of the sidebar. |

On the Mac, each earned achievement is a round badge, earliest first. Hold the pointer on a
badge to see its title and date. A count such as **3 of 7** is next to the badges, and a
**Next:** line under them says how to earn the first achievement that is still to earn. With
none earned, only the **Next:** line shows. With all seven earned, only the badges show. A
badge that you earn while the page is open grows into place, with no movement under Reduce
Motion.

On the web page, the page has the heading **Achievements** and a count such as **3 of 7**. Earned achievements
come first, earliest first, each with its date. The rest follow, greyed, each with its
line on how to earn it.

On the web page, the **Achievements** row shows only while an achievement is still to earn, as an empty smart
group hides. When you have earned all seven, the row goes and the list moves under the
charts on the **Time** page. See [See usage, cost and time](../how-to/see-usage-cost-and-time.md).

### When you earn one

| Client | What you see |
| --- | --- |
| Mac | A small card near the top of the sidebar: **Achievement**, its title, and **See Achievements**. |
| iPad | The same card at the bottom right of the screen. |
| Web page | The same card at the bottom right of the page. |
| iPhone | No card. The achievement has a **New** mark on the **Achievements** page until you leave the page. |

**See Achievements** opens the page (on the Mac, the **Multiplier** page). Each card shows once: it goes when you close it or open
it. Agents never sends a notification for an achievement. On the first look from a device or
a browser, the achievements earned before are not news, so they show no card.

### Hide it

Click or tap **×** on a card (**Dismiss achievement**) to close it. The list itself has no
switch to hide it. Its sidebar row goes by itself when you have earned every achievement.

## See also

- [Your first agent](../tutorials/first-agent.md)
- [Connect a window or phone](../how-to/connect-a-window-or-phone.md)
- [Set up a workflow](../how-to/set-up-a-workflow.md)
- [See usage, cost and time](../how-to/see-usage-cost-and-time.md)
