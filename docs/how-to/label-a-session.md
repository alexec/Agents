---
diataxis: how-to
devices: [mac, iphone, ipad, server]
description: Add session labels, find labeled work, and see who owns each label.
---

# Label a session

Use labels to tell similar sessions apart and find them later in the same project.
Each session can have up to five labels. A label has 1–24 characters; surrounding
spaces are removed, and capitalization does not make a second label.
Server projects can be labeled from the Mac. iPhone and iPad show Mac projects only.

## Add labels

Labels are edited in one field at the top of a session's chat, on the Mac, iPhone
and iPad, and in the same kind of field before you start a new session. Type a
label and press comma, or Return, to add it; a pasted `perf, ui` adds both. As
you type, labels already used in the project are offered: on the Mac in a list
under the field, on iPhone and iPad as chips after it. Suggestions come from
sessions still in the project, including archived ones, and disappear after the
last use is removed. The session list shows a session's labels but does not
change them.

## Remove a label

Press Delete with the cursor at the start of the field to remove the label just
before it. With a keyboard, the left arrow moves the cursor onto the labels and
Delete removes the one it is on. Each label also has its own **×**. Removing it
from one session leaves the other sessions' labels alone.

Labels you add are yours. An agent may label its own work through `finish_turn`,
and a helper or workflow can start with agent-owned labels. Agent-owned labels
have an outline; your labels have a filled background. The label's owner is also
read aloud. You can remove either kind, while an agent cannot remove or claim
one of yours.

## Find a session

Search the project's sessions for `label:review` to find the **review** label.
Capitalization does not matter. Add ordinary words to narrow the result, such
as `label:review login`; both the label and the title or last report must match.
Use quotes for a label with spaces: `label:"code review"`.

Search includes archived sessions. On the phone it loads the full project archive
for the query, even when only the newest ten archived cards were previously shown.
If nothing matches, the session list says so. A new chat starts with its own
labels; it does not copy labels from the session whose work you continue.

## See also

- [Tools the app gives agents](../reference/agent-tools.md)
- [Stop, park and archive agents](archive-park-stop.md)
