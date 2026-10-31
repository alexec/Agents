---
diataxis: reference
devices: [iphone, ipad]
description: Every swipe, long press, pull and menu in the iPhone and iPad app, and what each one does.
---

# Gestures on the iPhone and iPad

This page lists the gestures in the iPhone and iPad app: swipes on rows, long presses,
pulls, the chat's **···** menu, the edge pull for panes and the folder terminal. The Mac
window does most of these with a right-click or a two-finger swipe, and the web page with
a row's **···** menu.

A long press on a row opens the same menu that a right-click opens on the Mac, less what
the phone leaves to the Mac, such as **Show in Finder** and **Folder Settings**.

## Session rows

These work on a session's row in the sidebar, and on its card on the folder's page.

| Gesture | What it does |
| --- | --- |
| Tap | Opens the chat. |
| Swipe right | **Pin** or **Unpin**. On an archived card on the folder's page, **Unarchive**. |
| Swipe left | **Archive**. A long swipe archives at once, as in Mail. In the sidebar, a session that is done also shows **Mark as Read** or **Mark as Unread**. On an archived session, **Unarchive**. |
| Long press | The session's menu. See below. |
| Drag out of the sidebar | On an iPad, opens the session in a window of its own. |

The session's menu has these, when they apply:

- **Stop**, and **Stop All** for a session that started others that still run.
- **Carry on**, for a session that is blocked.
- **Open in New Window**, on an iPad.
- **Mark as Read** or **Mark as Unread**, for a session that is done.
- **Rename…**, **Pin** or **Unpin**, and **Move Up** and **Move Down** for a pinned session.
- **Branch** and **Archive**.
- **Keep Session**, for a session that asks to be archived. The session stays.
- **Unarchive** and **Delete…**, for an archived session.

## Other rows

| Row | Swipe right | Swipe left | Long press |
| --- | --- | --- | --- |
| A folder's heading in the sidebar | | | **New Session**, **Open in New Window** on an iPad or **Open Folder Alone** on an iPhone, **Put Files in Drop Box…**, **Pin** or **Unpin**, **Archive…** |
| A workflow | **Pin** or **Unpin** | **Archive**, or **Unarchive** | **Approve** and **Deny on This Host** while it waits for your OK, **Run now**, **Pin** or **Unpin**, **Move Up** and **Move Down** when pinned, **Turn Off** or **Turn On**, **Archive** or **Unarchive**, **Delete…** |
| Something that waits for your OK, under **Needs You** | | | **Review…**, the answers it takes (such as **Approve**, **Deny**, **Keep** or **Undo**), and **Request Changes…** |
| A pinned page | | | **Move Up**, **Move Down**, **Unpin** |
| An archived folder | **Unarchive** | **Delete** | **Unarchive**, **Delete…** |
| A worktree | | **Remove…**, **Remove Build Output** | **Remove Build Output**, **Remove…** |
| A runtime, on **Runtimes** | | **Mark available**, when it is out | |

A tap on a folder's heading, or on its **Workflows** row, folds or unfolds it.

## Pull down to refresh

Pull down on these lists to ask the control plane again: the sidebar (archived folders
too), a workflow's page, **Runtimes**, the cost and token pages, worktrees, events,
connectors, reports, **People** and the machine providers. The app also catches up by
itself when it connects and each time you go back to it, so a pull is for when you think
it has missed something.

## In a chat

| Gesture | What it does |
| --- | --- |
| Pull in from the right edge | Opens the **Exchanged** pane. The pull must start within 24 points of the right edge (#1580). A swipe that starts anywhere else scrolls the chat, also when it goes a little sideways, so that you do not open a pane by mistake while you read. |
| Swipe in from the left edge | The system's Back. |
| Long press on a message | **Copy Message**. On the agent's reply, also **Quote in Prompt**. On a prompt of your own, also **Branch from Here**. |
| Long press on a prompt in **Prompts** | **Copy** and **Branch from Here**. The row's **···** button opens the same menu, because a touch screen has no right-click. |
| Pinch on the Page | Zooms the page in and out. |

### The chat's ··· menu

On an iPhone, the chat's bar has only one button, **···** (#1020). A phone's bar has no
room for more, so everything else is in it, in this order:

- **Carry on**, first, while the session is blocked.
- **Find in Chat**, **Prompts** and **Open File…**.
- The panes: **Page** once there is one, **Files**, **Terminal** and **Simulator**, then
  **Exchanged**. They are left out when the Mac is too old to give them, except
  **Exchanged**.
- **Rename…** and **Branch**.
- **Pin** or **Unpin**, and **Archive**.
- **Unarchive**, in place of the last three, on an archived session.

On an iPad, the bar has room. **Carry on**, **Pin** or **Unpin**, **Archive** or
**Unarchive**, and **Panes** are buttons of their own. The **···** menu keeps **Find in
Chat**, **Prompts**, **Open File…**, **Exchanged**, **Open in New Window**, **Rename…** and
**Branch**.

## Panes

On an iPad with room for it, a pane opens as a column on the right of the chat, as on the
Mac. Drag the line between the chat and the column to make the column wider or narrower.
On an iPhone, or an iPad without room, the pane opens over the chat, and Back closes it.
The switch at the top of a pane goes to the others: **Page**, **Files**, **Changes**,
**Terminal**, **Exchanged** and **Simulator**.

## The folder terminal

**Folder Terminal** opens the folder's own shells, in the folder on its host
(#418). They are the shells that Control-\` opens on the Mac. They are not an agent's, so
they stay in the folder whichever session you open.

- Open it from **Folder Terminal** in the bar of any page of the folder.
- On an iPad with a keyboard, press Control-\`.
- Each shell is a tab. Closing a tab ends its shell. **End Shell** ends the shell in front.
- **Done**, or Control-\` again, puts the shells away and leaves them running.

Away from home, through the relay, the folder terminal and the panes say they need the
same network, because a shell sends too much for iCloud.

### Keys above the keyboard

A shell has a row of keys that a touch keyboard does not have: **^C**, **esc**, **tab**,
**ctrl**, the four arrows, **|**, **~**, **/** and **-**. **^C** interrupts what runs with
one tap. It is a key of its own because it is the key you need in a hurry, and **ctrl**
then **c** is two taps.

## With a keyboard on an iPad

| Keys | What they do |
| --- | --- |
| Command-P | **Open File…** in the chat. |
| Command-F | **Find in Chat**. |
| Shift-Command-P | **Prompts**. |
| Control-\` | **Folder Terminal**. |
| Command-+, Command-− and Command-0 | Zoom the Page in, out and to its actual size. |

## See also

- [Keyboard shortcuts](keyboard-shortcuts.md)
- [Use a shell in an agent's folder](../how-to/use-a-shell.md)
- [Stop and archive agents](../how-to/archive-and-stop.md)
- [How the phone and iPad reach your agents](../explanation/phone-and-ipad.md)
