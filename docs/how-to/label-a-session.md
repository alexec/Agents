---
diataxis: how-to
devices: [mac, iphone, ipad, web, server]
description: Add session labels, find labeled work, see who owns each label, and rename a session.
---

# Label a session

Use labels to tell similar sessions apart and find them later in the same folder.
Each session can have up to five labels. A label has 1–24 characters; surrounding
spaces are removed, and capitalization does not make a second label.
Server folders can be labeled from the Mac. iPhone and iPad show Mac folders only.

## Add labels

On the Mac, labels are edited in one field in the row above the prompt, beside the
folder and **Reach** for a new session and beside the worktree for an open one. On
iPhone and iPad the field is at the top of the chat and in the new-session sheet. Type a
label and press comma, or Return, to add it; a pasted `perf, ui` adds both. As
you type, labels already used in the folder are offered: on the Mac in a list
under the field, on iPhone and iPad as chips after it. Suggestions come from
sessions still in the folder, including archived ones, and disappear after the
last use is removed. The session list shows a session's labels but does not
change them.

## Remove a label

Press Delete with the cursor at the start of the field to remove the label just
before it. With a keyboard, the left arrow moves the cursor onto the labels and
Delete removes the one it is on. Each label also has its own **×**. Removing it
from one session leaves the other sessions' labels alone.

Labels you add are yours. An agent may label its own work with `set_session_labels`,
and a helper or workflow can start with agent-owned labels. Agent-owned labels
have an outline; your labels have a filled background. The label's owner is also
read aloud. You can remove either kind, while an agent cannot remove or claim
one of yours.

## Find a session

Search the folder's sessions for `label:review` to find the **review** label.
Capitalization does not matter. Add ordinary words to narrow the result, such
as `label:review login`; both the label and the title or last report must match.
Use quotes for a label with spaces: `label:"code review"`.

Search includes archived sessions. On the phone it loads the full folder archive
for the query, even when only the newest ten archived cards were previously shown.
If nothing matches, the session list says so. A new chat starts with its own
labels; it does not copy labels from the session whose work you continue.

## Rename a session

A runtime names each session from its first prompt, and it can change the name later.
Give a session a title of your own when the runtime's name does not tell it apart. Your
title stays: the runtime's later names do not replace it.

- **Mac:** choose **Rename…** from the session's context menu in the sidebar or from the
  **Session** menu, or click **Rename** in the toolbar above the chat. You can also
  double-click the session's row, or highlight one row and press Return. The title
  becomes a field in the row, or in a popover under the toolbar.
- **iPhone and iPad:** long-press the session and tap **Rename…**, or tap **···** in the
  chat and tap **Rename…**. Type the title in **Rename Session** and tap **Rename**.
- **Web page:** choose **Rename…** from the session's menu in the sidebar or from **···**
  in the chat's header, or double-click the session's row. The title becomes a field in
  the row or in the header.

On the Mac and the web page, press Return to keep the title, or Escape to cancel. A
title is one line, with runs of spaces made into one, and 80 characters at most.

To give the session back the runtime's name, empty the field and keep it. The field shows
the runtime's latest name as its placeholder. An archived session cannot be renamed.
Agents see the new title too, in `list_sessions` and `read_session`.

## See also

- [Tools the app gives agents](../reference/agent-tools.md)
- [Stop and archive agents](archive-and-stop.md)
