# Contract: The panes on iPhone and iPad (034)

What the person sees and can do. These are the things the walk checks. What the Mac draws is
the reference, and where this says "as on the Mac", the shared view is the Mac's.

## Getting to a pane (FR-024, SC-003)

| From | Tap | Result |
|---|---|---|
| Chat top bar | **Panes** button (`sidebar.right` on iPad, `doc.text` on iPhone) | Opens this agent's last pane. If none has been opened: the Page when the agent has shown a Markdown file, otherwise Files. |
| Pane's top | Segmented **Page · Files · Terminal · Exchanged** | Switches. Page is present only once a Markdown file has been opened for this agent. There is never a Browser segment (FR-030). |
| A file name in a tool call | tap | Files, with that file open at the named line (FR-014) |
| Exchanged entry naming a file in scope | tap | That file, live: a Markdown file on the Page, otherwise in Files (FR-027) |
| Exchanged entry only in the conversation | tap | As today: the document drawn from the conversation |
| Chat menu (`…`) | Exchanged | Kept, and it opens the Exchanged pane |

A file two folders down is four taps from the chat: Panes, folder, folder, file.

## Where it sits (FR-025, US5)

- **Column** when the window is at least 1,021 pt wide (`PanePlacement`). The chat keeps its
  reading width on the left, and the pane is on the right. A drag handle between them resizes
  the pane between 360 pt and half the window. A close button on the pane's bar closes it.
- **Full screen** otherwise, pushed on the chat's navigation stack. Back returns to the chat
  at the same scroll position.
- Rotating, or changing Split View, moves the pane between the two without losing its place.
  The place is `PaneState`: pane, folder, file, line and scroll.
- Going to another agent and back finds that agent's pane as it was (FR-026). A relaunch
  forgets it.

## Page (US1, US2)

- It is drawn by the shared `LivePage`: the same type, measure, caret with the agent's name,
  marks and collision card as on the Mac.
- It follows the file on disk. It needs no tap and has no pull-to-refresh.
- **Tap a passage** to open it for typing. It opens in place as plain text, and the phone's
  keyboard comes up. Saving happens after a 1 s pause and when the passage is left.
  - While a save is in flight, nothing is shown.
  - When a save fails: "Not saved: \<reason\>" under the passage, with the draft kept and
    selectable.
- **The agent writes elsewhere while a passage is open**: the rest redraws, and the view does
  not move.
- **The agent writes the same passage**: the collision card, "The agent changed this passage
  while you were typing. Yours is kept; theirs is below.", with Use theirs and Keep mine.
- **Stale**: the page keeps its text under the stale banner. Tapping a passage does nothing,
  and an open passage becomes read-only with its draft still visible. On reconnect it is
  saved, or it says "Not saved".
- **The file is gone**: "plan.md is gone." Its last contents stay, dimmed, and any draft
  stays with them.
- **A picture**: drawn at its reference. When its file changes, it is redrawn and marked.
  Missing: its alternative text.

## Files (US3)

- **The bar**: Back (in a subfolder: up one level; on a file: back to the listing), the folder
  or file name, truncated at the head.
- **The listing**: folders first, by name. A file the agent changed has the Mac's dot. A
  listing over 5,000 entries ends "N more, not shown".
- **A text file**: `FileLines`, with numbered lines and the named line tinted. A cut file
  starts "Showing the first 128 KB of 3.2 MB."
- **A Markdown file**: the Page.
- **An image**: the picture, fitted, and pinch to zoom.
- **Anything else**: one sentence, e.g. "A 2.1 MB SQLite database. It can't be shown here."
- **What the agent did**: a button on the bar, shown when the transcript has diffs for this
  file. It opens today's diff view (`ChangesView`, formerly `FileView`) over the file.
- **Out of scope**, e.g. a symlink out: the Mac's refusal sentence, as a row.
- **A folder or file that is gone**: "\<name\> is gone." Old contents are never shown as
  current. **A removed worktree**: "This agent's folder is gone."
- **Stale**: the last listing and file stay under the stale banner.

## Terminal (US4)

- SwiftTerm's view, in the paper colours as on the Mac. It attaches to the agent's shell with
  its scrollback. When bytes were dropped, a line at the top says "Earlier output was
  dropped."
- **The key row** above the keyboard: **^C · Esc · Tab · ← ↑ ↓ → · Ctrl · | ~ / -**. Ctrl is
  sticky for one key. Each of ^C, Esc, Tab and the arrows is one tap (SC-005).
- **An iPad hardware keyboard**: keys go straight through. Control, Escape and the arrows
  work.
- **Size**: sent on layout, and with every keystroke batch. The shell takes the size of the
  last device that typed.
- **Exited, failed to start, or let go while idle**: says which (the daemon's sentence), keeps
  the output readable, and offers **Start again**.
- **Stale**: output frozen, the keyboard dismissed and input disabled. When the connection
  returns, it re-attaches and replays.
- Leaving the pane or the app detaches. The shell keeps running on the Mac (FR-023).

## "Look at this" (FR-004, FR-005)

| Situation | What happens |
|---|---|
| The agent's chat is in front, and nothing is being typed | The pane opens on the file: a Markdown file on the Page, otherwise in Files at the line |
| The chat is in front and Alex is typing (prompt, a passage, the terminal) | A strip under the top bar: "Wants you to see **plan.md**", with **Open** and ✕ |
| Another screen is in front | Nothing takes the screen. The strip is waiting when that chat is next opened, for as long as the Mac still holds the request. |

## An older Mac (FR-029)

When the Mac answers `files/*` with "method not found":
- Panes opens today's views: the Exchanged list and the document drawn from the conversation.
- A tool call's file opens today's diff view.
- There is no terminal, and no empty segment for it.
- One line at the top of the pane: "Update Agents on your Mac to read files and use the
  terminal here."
