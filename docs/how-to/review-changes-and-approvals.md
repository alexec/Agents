---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Read a change that waits for your OK on its Review page, and answer it from the page, the card or Needs You.
---

# Review changes and approvals

Some changes do not take effect until you approve them. The app keeps using the version you
approved last, so a change that you did not read cannot change what agents do. Two kinds of
change wait for your OK:

- A **workflow** that is new, or that changed since you approved it. It does not run until
  you approve it.
- A **file**: one of the app's own files in the folder's `.agents` folder, changed outside
  the app (by an agent, a pull or an editor). The app goes on using the copy you approved
  last until you choose.

Each one is listed under **Needs You** at the top of the sidebar, and has a **Review** page
that shows the whole change. A chat that asks to be archived is in **Needs You** too; see
[Approve archiving a chat](archive-and-stop.md#steps) for that.

## Before you start

- A folder with a change that waits for your OK. Its row under **Needs You** has an orange
  shield.

## Open the Review page

1. Under **Needs You**, find the row. It shows the title, the folder, how long it has
   waited, and one grey line that says what changed, for example **New**, **Changed by**
   an agent, **Changed with the last pull** or **Changed since you approved it**.
2. Open the row:
   - On the Mac, click it. The page opens in the main column.
   - On an iPad, tap it. The page opens in the main column.
   - On an iPhone, tap it. The page opens as a screen of its own.
   - On the web page, click it. The page opens in the chat's place.

You can also open the page from the short card in a chat. When an agent changes a file,
the card shows above its prompt with who changed it, the lines added and removed
(**+N −M**), **Review…**, **Undo** and **Keep**. Click **Review…** to read the whole change.
When no agent made the change, the card is on the folder's page. On the Mac it is also in
Folder Settings.

## Read the change

The page shows, from the top:

- The title, what kind of change it is (**Workflow** or **File**), the folder, and when it
  began waiting.
- Who changed it. If an agent did, click **Open Session** to go to that agent's chat.
- What each answer does, in one short paragraph.
- The file's path, the count of lines added and removed, and the whole change, line by
  line.

When the page is wide, choose **Unified** or **Side by Side** to see the old file beside
the new one. A narrow page always shows **Unified**.

A change of more than 400 lines is cut. The page says so. Open the file in the folder to
read the rest.

## Answer it

The answers stay in a bar at the foot of the page, so you can answer at any point while
you read. Which answers you see depends on the kind:

| Kind | Approve | Deny | Request Changes |
| --- | --- | --- | --- |
| Workflow | **Approve**: it runs from now on. | **Deny**: it stays off on this host until its file changes again. | Not offered. |
| File | **Keep**: the app uses the change from now on. | **Undo**: the approved copy goes back into the file. | **Request Changes…**, only when an agent made the change. |

To ask the agent for changes:

1. Click **Request Changes…**.
2. Type what to change in the field **What to change, for the agent that made it**.
3. Click **Send to the Agent**. Or click **Cancel** to go back.

The note goes to that agent as your message. The change keeps waiting, and the agent's
next version asks again. This lets the agent fix its own change, instead of you editing it.

When the answer is done, the page closes. If it changed again while you read it,
the answer is refused and the page says why. This makes sure you never approve a version
that you did not see. Open the row again to read the new version.

## Answer without the page

When you already know the answer, use the row's menu under **Needs You**:

- On the Mac, right-click the row.
- On iPhone and iPad, touch and hold the row.
- On the web page, right-click the row, or touch and hold it.

The menu has **Review…** and the answers for that kind. **Request Changes…** opens the page,
because it needs a note. Each row is answered on its own.

## See also

- [Stop and archive agents](archive-and-stop.md)
- [Set up a workflow](set-up-a-workflow.md)
- [Read an agent's changes](read-an-agents-changes.md)
- [Statuses and groups](../reference/statuses.md)
- [The sidebar](../reference/sidebar.md)
