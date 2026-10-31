---
diataxis: reference
devices: [mac, iphone, ipad, web]
description: What the sidebar holds, in what order, which groups start on or off, and how read and unread show.
---

# The sidebar

The sidebar is the same list on every client: the Mac window, the Remote on iPhone and
iPad, and the web page. On the Mac and the iPad it is beside what you open. On an
iPhone, and on a narrow web page, it is the first screen, and what you open goes over it.

## What it holds, in order

| Part | What it is |
| --- | --- |
| **New Session** | Starts a session in the folder you last started one in. The page it opens can change the folder. |
| **Status** | Pages about the work going on now: **Events**, **Resources**, **Runtimes**, **Connectors** and **Worktrees**. |
| **Usage** | Pages about past work: **Cost**, **Tokens**, **Time**, and **Milestones** until you have done every first step. |
| Smart groups | **Pinned**, **Needs You**, **Working** and **Unread**, each across every folder and host. See [Smart groups](#smart-groups). |
| One group per folder | Each folder's own sessions and workflows. See [A folder's group](#a-folders-group). |
| **Archived folders** | Folders you put away. The heading stays folded until you open it. Each has **Unarchive**. |
| The foot | Lines about this Mac's host and the servers, when there is something to say. On iPhone and iPad, **Settings…**. On the web page, **Settings** and **Help**. |

There is no heading for each host. Pinned folders come first, then the rest. In each of
the two, this Mac's folders come first, then each server's, in the order you added them.
A server's folder shows the server's name before its own, such as `devbox:api`. A row
stays in its place however busy its folder is.

**Status** and **Usage** each fold, as a folder does. Both start open. A row in **Status**
shows its icon in red when something is wrong: **Runtimes** when no runtime can start,
and **Connectors** when a connector does not answer.

## Smart groups

The smart groups gather sessions from every folder and host, so you can see what wants
you without opening each folder.

| Group | What it lists | At first |
| --- | --- | --- |
| **Pinned** | The sessions and workflows you pinned, in the order you pinned them. | On, open |
| **Needs You** | Sessions that asked you something, are blocked, or ask to be archived. Also each approval that waits for you: a connector, a workflow, a plugin, a guarded file, and a workflow that failed. | On, open |
| **Working** | Sessions with a turn in progress. | Off |
| **Unread** | Finished sessions you have not opened since they finished. | Off |

**Working** and **Unread** start off, so the sidebar first shows only what needs you.

- **Each session is listed once.** It goes in the first group it fits, in the order of the
  table. A session in no smart group is under its folder only. An archived session is in
  no smart group.
- **A group with nothing in it is not shown.** While you search, a group shows only when
  something in it matches.
- **A row in a smart group shows its folder's name** after its title, in grey.
- **A session you open from Unread stays there,** read, until you open another one. This
  keeps the row from moving away under the pointer.

### Turn a smart group on or off

Turn each group on or off under **Smart groups** in **Settings ▸ This app ▸ Sidebar** on the Mac,
in **Settings…** at the foot of the sidebar on iPhone and iPad (under **This app**), and under
**Sidebar** in **Settings ▸ This browser** on the web page. The choice is kept on your Mac, so every
client shows the same groups. A group that is off is not shown. Its sessions go to the next
group they fit, or under their folder. With **Needs You** off, approvals are not listed
in the sidebar.

The choice is kept on your Mac, with your other display choices, so every client shows
the same groups.

## A folder's group

The folder's name is the group's heading. The heading has no count: the **Sessions**
fold counts the sessions. A folder starts folded. Click or tap its
heading to open it. In order, an open folder holds:

- **Its pinned pages,** when it has some.
- **Its sessions,** newest started first. Its pinned sessions are in **Pinned** instead.
  Each row's mark says its state. See [Statuses and groups](statuses.md).
- **Workflows,** a fold with a grey count of the folder's workflows. It is closed at
  first, and each folder keeps its own fold. A search opens it to show what matched. It
  shows only when the folder has a workflow that is not archived and not pinned. Pinned
  workflows are in **Pinned**.
- **Connectors,** a row that opens the folder's connectors, with how many it has. It is
  red when one does not answer.
- **Archived,** a row that opens a page of the folder's archived sessions and
  workflows. It shows only when there is something archived.

While you search, the archived sessions and workflows that match show in the folder's
group instead, the first 10 with **Show all** for the rest.

## Sessions under the session that started them

A session that another session started is listed one step in, under the session at the
top of its chain. A lead's lanes and the lanes' helpers all sit one step in under the
lead, oldest first. This keeps the sidebar to a fixed depth however deep the chain is.

- **A parent shows a count and a chevron** at the end of its row. Click or tap the count to
  show or hide the sessions it started. A parent starts folded, and the sidebar keeps the fold
  of each row.
- **A folded parent shows the most urgent mark** of itself and the live sessions under
  it, so a folded child that needs you is not hidden.
- **A child is under its parent only when the same list holds the parent.** When the
  parent is in another group, the child is a row of its own, with a mark that says which
  agent started it.
- **Archive takes the children too.** Archive on a parent, from its menu, its swipe or
  the Delete key, archives its live children as well.
- **Stop All** is in a parent's menu while it or a session under it can stop. It stops
  them all.

## Read and unread

A session that finishes while you are not looking at it is unread. Its row stays where
it is in its folder, or goes to **Unread** when that group is on.

- **In the sidebar, the mark is a bold title.** A finished session has the same empty
  ring as its mark, read or unread. Only an unread one has a bold title, and a screen
  reader reads it as "unread". The dot before the title is on the folder's page, not in
  the sidebar.
- **Only a finished session is bold.** A session that asked you something, is blocked or
  ended without a report is never bold, read or not, because its hand mark already asks
  for you. A finished session that asks to be archived stays bold, with its orange
  archive mark.
- **Opening the session reads it.**
- **Mark as Unread** leaves a finished session to come back to. **Mark as Read** clears
  the mark without opening it. On the Mac they are in the row's menu. On iPhone and iPad,
  swipe the row to the left. On the web page, right-click the row or press its menu key.

The counts, the Dock badge and the widget are on [Statuses and groups](statuses.md#unread).

## Where each client differs

| | Mac | iPhone and iPad | Web page |
| --- | --- | --- | --- |
| A row's actions | Right-click for its menu. Command-click to choose several rows, then press Delete to archive them all. | Long press for its menu. Swipe left for **Archive** and **Mark as Read** or **Mark as Unread**; a long swipe archives. Swipe right to pin. | Right-click, the menu key or Shift-F10 for its menu. |
| Keys | The arrow keys move through every row. Return renames the session you chose. | | Up Arrow and Down Arrow move through every row and open it. Right Arrow unfolds and Left Arrow folds. |

## See also

- [Statuses and groups](statuses.md)
- [Label a session](../how-to/label-a-session.md)
- [Stop and archive agents](../how-to/archive-and-stop.md)
- [Settings](settings.md)
