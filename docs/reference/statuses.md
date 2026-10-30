---
diataxis: reference
devices: [mac, iphone, ipad]
description: Every status an agent can have, the group it is listed under, and what you can do from there.
---

# Statuses and groups

Only a question puts a session under **Needs you** (#1916): the app does not assume an agent needs you unless it asks. An agent that waits on other agents or a time is under **Waiting**.

This page lists every status an agent can show, and the group it sits under on its
folder's page. The groups appear in this order: **Needs you**, **Waiting**,
**Working**, **Done**, **Paused**. A group with no agents in it is not
shown. Archived chats stay under **Archived sessions**, folded away until you open it.

The status is what the agent's icon says when you hover over it, and what a screen reader
reads. The Mac, iPhone and iPad use the same words. Only **Needs you** is drawn in
colour.

While a session is under **Needs you**, its sidebar row uses the grey line to say why: the
first line of its pending question, why it stopped, or **Finished without saying how it
went**. The status mark's tooltip and VoiceOver label say the precise status too. The
session's last report returns to the row when it leaves **Needs you** (#1324).

In the sidebar, each session has a mark for what it wants: an orange hand when it needs
you, a spinning ring of dots while it works, a numbered list while it is queued, Zs while
it waits, a pause mark when it is paused, and a tick when it is done. All but the hand
are in the accent colour.

Session labels appear beneath the title on Mac rows and phone cards; agent-owned labels use an outline, while person-owned labels have a filled background. The phone shows two labels on a card and a **+N** count for the rest. Labels remain on archived sessions.

| Status | Group | What it means | What you can do |
| --- | --- | --- | --- |
| **Starting** | Working | The agent has been made and its first turn is about to begin. | **Stop**, **Archive**, **Branch**. |
| **Working** | Working | A turn is in progress. The row's mark is the spinner while the agent thinks or replies, and a wrench while it runs a tool. The wrench's tooltip, or VoiceOver on the iPhone and iPad, names the tool: **Running: swift test**. A tool that ends within a second does not show. | **Stop**, **Archive**, **Branch**. A prompt you send waits until the turn ends, unless you click **Send now** on it. |
| **Coming back after a restart** | Working | The app is bringing the conversation back by itself after the app or the Mac restarted. | **Stop**. |
| **Waiting on you** | Needs you | The agent has asked you something in the middle of its turn, such as permission to run a command, and is paused until you answer. | Answer the card above the prompt. **Stop**, **Archive**, **Branch**. |
| **Waiting on your answer** | Needs you | The turn ended with a question for you. | Reply in the prompt. **Archive**, **Branch**. |
| **Outcome unknown** | Needs you | The turn ended without a report saying how the work went. | Read the conversation and reply if needed. |
| **Unexpected stop** | Needs you | The runtime crashed, failed, hit a limit or otherwise stopped short without you choosing to stop it. | Read the reason on the row and reply to resume. |
| **Waiting** | Waiting | The agent is waiting on something the app watches: agents it started, a time to check again, or an event such as checks passing. The card says what it is waiting for. It carries on by itself when that comes, so you need not do anything. Its icon is Zs: asleep until what it waits for comes. | **Carry on**, to tell it the wait is over early. **Stop**, so it does not carry on. **Archive**, **Branch**. |
| **Complete** | Done | The agent did what was asked. A turn with no question, no file and no archive ends so. An old record's **Stuck**, **Partly done** or a wait on nothing the app watches shows as **Complete** too (#1916). | Reply in the prompt. **Mark as Unread**, **Archive**, **Branch**. |
| **Nothing to do** | Done | The agent found nothing that needed doing. | Reply in the prompt. **Mark as Unread**, **Archive**, **Branch**. |
| **Stopped by you** or **Stopped by the agent that started it** | Paused | The turn was deliberately cut short. | Reply in the prompt to start a new turn. **Archive**, **Branch**. |
| **Its allowance ran out** | Needs you | The runtime refused the turn because its plan's allowance, or a key's credit, is spent. The session ended in error. | **Continue at 07:00** (or **Continue when it is back**), so the chat carries on by itself when the allowance is back. Or start a new chat on another runtime and ask it to continue this one; see [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md). Or reply here once the runtime is back. **Archive**, **Branch**. |
| **Waiting for an allowance** | Waiting | You chose **Continue at…** on a chat whose allowance ran out. Its row says **Continues at 07:00**. At that time, or sooner when a turn on that runtime works or you mark it available, the app sends "continue" in the same chat. | **Cancel**, so it does not carry on. A message of yours, **Stop** or **Archive** cancels it too. |
| **Archived** | Archived | You, the agent that started it, or a workflow's run allowed to, put it away; or the app did, when its pull request merged (Folder Settings ▸ General ▸ **Pull request merged**). If the app made a worktree for it and everything in it is committed, the worktree is removed; its branch is deleted too if it was merged. | **Unarchive**. |

**Show in Finder** is on every agent's menu on the Mac.

## Unread

Unread is a mark on a row, not a group. A turn that finishes while you aren't looking at
it shows a dot before its title, and the title is bold, as in Mail. A screen reader reads
it as "unread". The row stays in its group: a completed turn is under **Done** from the
moment it ends, and opening it clears the mark without moving it. A question or an
unresolved problem is under **Needs you** whether you have read it or not.

Each group heading counts what is unread under it, such as **Done 5 · 2 unread**, and so
does the folder's row in the sidebar and on the phone. The Dock badge, the app icon badge,
the Home-screen widget and the tab's title count only what needs you: a question or an unexpected stop. An unread finish is not counted there (#1565).

## A file to see

A session whose agent showed you a file with `show_file` is not under **Needs you**:
**Needs you** means only that the agent cannot go on without you (#1802). The session stays
where its ending puts it, usually unread under **Done**, and its row has a small document
mark beside the title, and its grey line names the file in the report's place:
**File to see: report.md** (#1873). On the Mac you can also hover over the mark. The mark is not counted on the Dock badge, the app icon badge,
the widget or the tab's title, and the session is not in the **Needs You** list.

The mark goes when you open the conversation, which opens the file beside it, or choose
**Mark as Read**. A file shown while you are watching the conversation gets no mark.

To leave a finished conversation to come back to, choose **Mark as Unread** from its
menu. It stays unread until you open it again. **Mark as Read** clears the mark without
opening it.

## Muted

A muted session sends no notification on the Mac, no push and no banner. Nothing else
changes: it still goes under **Needs you** when it needs you, and it still counts on the
Dock badge, the app icon badge, the widget and the tab's title. Its row has a bell with a
slash (🔕) beside the title; on the Mac and in a browser, hover over it to read this. A
muted workflow's runs are muted sessions. See
[Mute the notifications for a session](../how-to/mute-notifications.md) (#2086).

## Archiving needs approval

**Archiving needs approval** is a mark on a row, like the unread mark, not a group. An agent
that thinks its work is finished archives its session with `archive_session`; where that
needs your approval, the row carries the mark once its turn ends. The session stays where its ending puts it: usually **Done**, or
**Needs you** with the mark beside it for one that is **Partly done**. Nothing is hidden
until you archive it.

- **A card at the end of the chat** says **The agent asks to archive this session**, in the
  attention colour, with what the agent said last. **Approve** archives it; **Keep Session**
  keeps it. It is drawn as a permission question is, on the Mac, iPhone, iPad and web page
  (#827).
- **Approve** is also beside the mark on the Mac's row. On the Remote and the web page,
  **Archive** is in the row's menu and its swipe.
- **Needs You** lists every session waiting for approval, across every folder and host
  (#773). Each row is approved on its own; there is no Approve All (#704).
- The mark goes when you send the session a prompt, when a later turn ends wanting you
  (with a question, stuck, waiting on others or crashed), or when the session is archived. Bringing
  it back does not bring the mark back. A workflow's prompt, or the app's own, leaves it.
- A session that may already archive itself is archived without your approval, if its turn
  ends **Complete** or **Nothing to do**: a chat you started, while **Agents may archive the
  chats I start** is on (the default; not when that turn showed you a file), a workflow's run
  whose workflow says `when-done: archive-allowed` or `archive`, and a helper in a folder
  where agents may archive the helpers they started.

A session parked before parking was taken out comes back, on first load, to the group its
last ending puts it in, usually **Done**, marked read.

## The phone's connection

The line at the top of the iPhone and iPad screens says how they are reaching the Mac.

| Line | What it means | What works |
| --- | --- | --- |
| No line | On the Mac's network, connected directly. | Everything. |
| **Away** — slower, through iCloud | On another network, reaching the Mac through your iCloud. | Everything but the terminal, the live page, files and attaching pictures, which say **Needs the same network as your Mac**. |
| **Away** — slower than usual | As above, while iCloud has asked the app to slow down. | As above, more slowly. |
| The relay needs iCloud on your iPhone and your Mac | One of them is not signed in to iCloud, or not to the same account. | Only the Mac's own network. |
| iCloud is full, so the relay can't carry messages | Your iCloud storage is full. | Only the Mac's own network. |
| Last heard from your Mac … | Neither way reaches the control plane: the Mac it runs on is asleep, or Agents Host is not running. What is shown is dimmed and offers nothing. | Nothing, until it answers. |
| Not connected to your Mac yet | The app has not reached the control plane since it opened. If it has not paired, the page says **Connect to your agents**, with a button to scan the code the Mac shows in **Settings ▸ Control plane ▸ Clients ▸ Pair a Device…**. | Nothing, until it answers. |

## See also

- [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)
- [Stop and archive agents](../how-to/archive-and-stop.md)
- [Answer a question or a permission request](../how-to/answer-a-question.md)
- [Events](events.md)
