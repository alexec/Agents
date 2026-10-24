---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Find words in the open chat with Find in Chat, or find a session by what was said in it.
---

# Find in a chat or a session

There are two searches. Each one finds what was said, so you do not have to scroll a
long chat or remember a session's title.

- **Find in Chat** finds words in the open chat: its prompts and its replies.
- **Find Session** finds a session in the sidebar by its title, its last report, its
  labels or what was said in it.

## Before you start

- A chat to search. See the [tutorials](../tutorials/index.md) to start one.

## Find words in the open chat

1. Open the chat.
2. Open the find bar:
   - On the Mac, press **⌘F** (Command-F), or choose **View ▸ Find in Chat**.
   - On iPhone and iPad, open the **Actions** menu at the top of the chat and choose
     **Find in Chat**. With a keyboard on an iPad, you can also press **⌘F**.
   - On the web page, press **⌘F** (Command-F) or Ctrl+F, or open the chat's
     **···** menu and choose **Find in Chat**. In the chat, **⌘F** opens this bar in
     place of the browser's own find.
3. Type the words in the **Find in Chat** field. Capitals do not matter. After a short
   pause, the host searches the whole chat, also the turns that are not loaded yet.
4. The chat goes to the newest match. The bar shows where you are, for example
   **2 of 7**. It shows **No matches** when nothing matches.
5. Go through the matches:
   - Press Return, or the up arrow, or click the **Earlier match** button, to go back
     through the chat.
   - Press Shift-Return, or the down arrow, or click the **Later match** button, to come
     forward.

   If a match is in an earlier turn, the chat loads that turn first. A match is not
   highlighted: the chat scrolls to the message that holds it.
6. Click **Done**, or press Escape, to close the bar.

**What it finds**

- Your prompts and the agent's replies. Tool calls, their output, thoughts and the
  runtime's subagents are not searched, so a match is always something you or the agent said.
- The newest 200 matches. When there are more, the count ends in **+**, for example
  **1 of 200+**.

**Where it is not**

- On the Mac, **Find in Chat** is in the main window only. In a folder's own window, or
  a chat in a window of its own, **⌘F** is **Find Session**.
- On iPhone and iPad, a chat in a window of its own has no **Find in Chat**.
- A host that is too old to search shows **Find in Chat** greyed, and asks you to update
  it. On the web page, **⌘F** is then the browser's own find.
- If the host cannot be reached, the bar says **Couldn't search this chat**.

## Find a session

1. Go to the search field at the top of the sidebar. It says **Search**.
   - On the Mac, press **⌥⌘F** (Option-Command-F) while a chat is open, or **⌘F**
     (Command-F) when no chat is open. Or choose **View ▸ Find Session**.
   - On iPhone and iPad, tap the **Search** field at the top of the sidebar.
   - On the web page, click the **Search** field at the top of the sidebar.
2. Type the words. The sidebar shows the sessions whose title, last report or labels
   match, and the sessions where you or the agent said the words.
3. When a session matches by what was said, its row shows the matching line in place of
   its grey report line, so you can see why it matched before you open it.
4. Archived sessions are found too. If a host has more matches than it sent, click
   **More matches…** at the end of the list.
5. Clear the field to see the whole sidebar again.

To find a label, type `label:` and its name, for example `label:review`. See
[Label a session](label-a-session.md#find-a-session).

**What it finds**

- Each host searches the newest part of each session's prompts and replies, about 32 KB
  of text, in its 300 most recently active sessions. This keeps a search fast on a host
  with many long sessions. To find words deep in one long chat, open the chat and use
  **Find in Chat**.
- A host that is too old to search what was said still finds sessions by title, report
  and label.

## See also

- [Label a session](label-a-session.md)
- [Read a chat](read-a-chat.md)
- [Keyboard shortcuts](../reference/keyboard-shortcuts.md)
- [Stop and archive agents](archive-and-stop.md)
