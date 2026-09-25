# Feature Specification: The Mac's Side Panes on iPhone and iPad

**Feature Branch**: `034-ios-artifacts`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Artifacts (etc) on iOS." Scope settled with Alex on 2026-09-24: live pages
(following the agent and typing on them), browsing and reading the agent's files, and the terminal come
to the phone. The browser stays at the Mac.

## Why this feature exists

On the Mac, the conversation has a column beside it with four panes: Files, Terminal, Browser and
Exchanged. Since 022, a Markdown file opened there is a live page. When an agent calls `show_file`
on a document, the page opens, fills as the agent writes, goes to where it is writing, marks what
changed, and lets the person type into it. The agent is then told what the person changed.

The phone has a small, read-only part of this. It has an Exchanged list reached from the chat's
menu, a document drawn once from what the conversation carried, and a "file" rebuilt from the diffs
the agent's edits left in the transcript. It is not the file on disk. When an agent says "look at
this" on the phone, a sheet shows that reconstruction, and it does not follow what the agent writes
next. Files the agent never edited cannot be opened. There is no shell.

013 kept it that way on purpose. Reading what the agent did came to the iPad, and driving the Mac
did not. That line has now moved. Much of an agent's work is a document the person and the agent
write together, and from the phone the person can only watch that in the chat. This feature brings
three of the four panes to iPhone and iPad as working panes, not as copies drawn from the
transcript:

- **Live pages**: the same page as the Mac's, following the agent and taken over by the person's
  typing.
- **Files**: the agent's folder as it is on disk now, browsable and readable, with what the agent
  changed marked.
- **Terminal**: the person's own shell in the agent's folder, the same shell the Mac's pane shows.

The **browser** stays at the Mac. Its main use is the agent's local servers, which only listen on
the Mac, and carrying web pages across the phone's connection is a feature of its own.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Watch the agent write, from the phone (Priority: P1)

Alex asks an agent from the phone to draft a spec. The agent shows the document, and the page opens
on the phone and fills as the agent writes. When the agent adds a section at the bottom, the page
goes to the bottom. When it goes back to rewrite the introduction, the page goes back too, and what
just changed is marked briefly. The Mac, if it has the same agent open, does the same thing at the
same time.

**Why this priority**: This is what "artifacts on iOS" means first. The agent's work is a document,
and the phone can currently only show it after the fact, as a reconstruction.

**Independent Test**: From the phone, ask an agent to write a short Markdown document in three or
four steps and to show it first. The page opens on the phone when the agent shows it. Each step
appears without a tap, and the view is on the latest change each time.

**Acceptance Scenarios**:

1. **Given** a conversation open on the phone, **When** the agent asks for a Markdown file to be
   shown, **Then** that file opens as a live page drawn from the file on disk, and it opens empty
   with the file's name if the file does not exist yet.
2. **Given** the page is open, **When** the agent changes the file, **Then** the page shows the new
   content within a moment, with no tap and no refresh.
3. **Given** a long document, **When** the agent changes one part, **Then** the view moves to that
   part and marks it briefly, the same as on the Mac.
4. **Given** several changes in quick succession, **When** they land, **Then** the page ends on the
   final state, with no flicker and no older version drawn after a newer one.
5. **Given** the agent names a line of the document, **When** it asks for it to be shown, **Then**
   the view goes to the passage that holds that line and marks it.
6. **Given** the document references an image beside it, including an SVG, **When** the page is
   drawn, **Then** the picture is shown at the reference. When the agent redraws the image, the
   picture changes and is marked.
7. **Given** a conversation open on the phone but another screen in front (the project, another
   chat), **When** its agent shows a file, **Then** it does not jump in front of Alex. The chat
   offers it (see FR-005).

---

### User Story 2 - Type on the page from the phone (Priority: P1)

Alex reads the draft on the phone and rewrites a paragraph with the phone's keyboard. The change is
saved to the file, and the Mac's page shows it. When the agent next acts, it knows the paragraph
changed and carries on from Alex's words. If the agent writes elsewhere in the document while Alex
is typing, the page redraws around the paragraph being typed and leaves it alone.

**Why this priority**: The Mac's page is shared, and a page the phone can only read is back to
saying "change this paragraph" in the chat. It is P1 because Alex asked for it with the page. It
comes after story 1 because it needs the page.

**Independent Test**: On the phone, edit a paragraph of an open live page, then ask the agent to
continue the document. The file on the Mac has the edit, the Mac's page shows it, and the agent's
next change builds on it.

**Acceptance Scenarios**:

1. **Given** a live page on the phone, **When** Alex taps a passage, **Then** that passage opens
   for typing as plain text, with the page drawn around it, as on the Mac.
2. **Given** Alex has typed, **When** they pause or leave the passage, **Then** the change is saved
   to the file on the Mac, and the Mac's page, if open, shows it.
3. **Given** Alex has changed the page, **When** the agent next takes a turn, **Then** it is told
   the document changed and where, in the same way as for a change typed on the Mac.
4. **Given** Alex is typing in one passage, **When** the agent writes to another part of the file,
   **Then** the rest of the page redraws, the passage being typed is left alone, and the view stays
   where Alex is typing.
5. **Given** the agent and Alex change the same passage, **When** both land, **Then** the collision
   is handled as it is on the Mac, and neither version is lost without being shown.
6. **Given** the connection to the Mac drops mid-edit, **When** it returns, **Then** what Alex
   typed is saved, or Alex is clearly told it was not and can still copy it. It is never silently
   lost.

---

### User Story 3 - Browse and read the agent's folder (Priority: P2)

Alex wants to check the config the agent keeps talking about. It never edited the file, so today
the phone cannot open it. From the chat, Alex opens the agent's files. They see the folder the agent
is working in (its worktree, if it has one), with what the agent changed marked. They go into a
subfolder and open a file, which reads as it is on disk now. A Markdown file opens as a live page.
A file a tool call touched, tapped in the transcript, now opens the file itself at that line.

**Why this priority**: Much of what the phone gets wrong now comes from not being able to read the
file. The diff reconstruction answers "what did the agent do", not "what is in there".

**Independent Test**: From a phone chat, open the files, walk two folders down, open a source file
the agent never touched and read it. Then open one it changed, and confirm it is marked in the
listing and shows current contents.

**Acceptance Scenarios**:

1. **Given** an open conversation, **When** Alex opens its files, **Then** the agent's working
   folder is listed, folders first, with files the agent changed since it started marked as on the
   Mac.
2. **Given** a text file, **When** it is opened, **Then** its current contents are shown with line
   numbers, and a file changed on disk while open shows its new contents without a tap.
3. **Given** a Markdown file, **When** it is opened, **Then** it opens as a live page (stories 1
   and 2).
4. **Given** an image, **When** it is opened, **Then** it is shown as a picture. A file that is
   neither text nor image says what it is instead of showing its bytes.
5. **Given** a file name in a tool call, **When** it is tapped, **Then** the current file opens at
   the named line. What the agent did to it stays one tap away, as it is today.
6. **Given** a large folder or file, **When** it is opened, **Then** the phone stays responsive. A
   very large file is shown in part, and the phone says so.
7. **Given** a folder or file that disappears while open, **When** that happens, **Then** the phone
   says it has gone and does not show old contents as current.

---

### User Story 4 - A shell in the agent's folder, from the phone (Priority: P2)

Alex wants to run the tests the agent says pass. From the chat, they open the terminal. It is the
same shell the Mac's pane has for that agent, with its scrollback. They type a command with the
phone's keyboard, use a row of extra keys for Control, Escape, Tab and the arrows, and watch the
output arrive. They put the phone away while the command runs. It keeps running on the Mac, and when
Alex comes back, from either device, it is still there with everything it printed.

**Why this priority**: It is the Mac's escape hatch for anything the panes do not do, and the one
way to check an agent's claim without the agent. It is P2 because a shell on a phone is used less
often than a page, and it has the most to get right on a touch screen.

**Independent Test**: Open an agent's terminal on the Mac and run something. Open the same agent's
terminal on the phone and confirm the same scrollback is there. Run a command from the phone,
interrupt it with Control-C from the extra keys, and confirm the Mac's pane shows the same session.

**Acceptance Scenarios**:

1. **Given** an open conversation, **When** Alex opens its terminal, **Then** a shell in the agent's
   folder is shown. It is the same shell as the Mac's for that agent, not a second one, and it has
   the same scrollback.
2. **Given** the terminal, **When** Alex types, **Then** input reaches the shell as typed, and output
   appears as it is produced, colour and cursor movement included.
3. **Given** the phone's keyboard, **When** the terminal has focus, **Then** a row of keys offers
   Control, Escape, Tab, the arrow keys and the common symbols a shell needs. On an iPad with a
   hardware keyboard those keys work directly.
4. **Given** the phone's screen size or orientation changes, **When** the terminal is redrawn,
   **Then** the shell is told its new size, and full-screen programs redraw to fit.
5. **Given** the terminal open on the Mac and the phone at once, **When** either types, **Then**
   both show the same session. The size the shell uses is the size of whichever device typed last.
6. **Given** the shell has exited, failed to start, or been let go while idle, **When** the
   terminal is opened, **Then** it says which, keeps what was printed readable, and offers to start
   it again.
7. **Given** the terminal is the person's, **When** anything is typed there, **Then** none of it
   reaches the agent, as on the Mac.

---

### User Story 5 - The panes sit where the screen has room (Priority: P3)

On an iPad in landscape, the pane opens in a column beside the conversation, as on the Mac. Alex can
watch the agent write in the chat and on the page at once, and switch the column between Page,
Files, Terminal and Exchanged. On an iPhone, or an iPad in a narrow split, the pane takes the
screen, and the conversation is one tap back. On every size, the pane belongs to the agent whose
chat it came from, and moving to another agent and back finds each pane where it was left.

**Why this priority**: Stories 1 to 4 work on any layout. This one decides whether they are pleasant
on a large screen, and it matches the iPad to the Mac.

**Independent Test**: On an iPad in landscape, open a live page beside a running agent's chat and
confirm both update at once. Rotate to portrait and to a narrow split and confirm the pane moves to
its own screen without losing its place. On an iPhone, confirm the same pane opens full screen and
the chat is one tap back.

**Acceptance Scenarios**:

1. **Given** an iPad wide enough for the chat's reading width and a pane, **When** a pane is opened,
   **Then** it is a column beside the conversation, and it can be closed and switched between
   Page, Files, Terminal and Exchanged.
2. **Given** a screen too narrow for both, **When** a pane is opened, **Then** it takes the screen,
   with a way back to the conversation, and the conversation keeps its place.
3. **Given** a pane open for one agent, **When** Alex moves to another agent and back, **Then** the
   first agent's pane shows what it showed (the same file, folder, scroll position and shell).
4. **Given** the Exchanged list, **When** an entry is a file in the agent's folder, **Then** it
   opens the file itself (a live page for Markdown). An entry that only exists in the conversation
   still opens as it does today.

---

### Edge Cases

- **The Mac goes quiet (stale)**: pages, files and the terminal keep what they last showed and say
  it may be out of date. Typing on a page or in the terminal is disabled, and a half-typed passage
  is kept on the phone. Nothing looks live when it is not.
- **An agent shows a file while Alex is typing on a page**: the passage being typed is not taken
  away. The request is offered, not forced.
- **An agent shows a file outside its folders**: the Mac already refuses this. The phone shows
  nothing more than the Mac would.
- **The file is deleted or renamed while its page is open**: the page says the document is gone and
  keeps its last contents and anything Alex typed, as on the Mac.
- **An archived or stopped agent**: its files and pages can still be read, and pages can still be
  typed on as on the Mac. Its terminal follows the Mac's rules for a shell whose agent has stopped.
- **A binary file, or a text file far bigger than a phone should hold**: said, not shown in full.
- **A worktree the agent is in has been removed**: the files say the folder has gone.
- **A full-screen program (an editor, `top`) in the terminal on an iPhone in portrait**: it is
  drawn at the phone's size. The extra keys can drive it, and nothing is cut off without a way to
  scroll to it.
- **Two phones and a Mac on one page**: each device's typing is saved as its own. The agent is told
  of the person's changes once, not once per device.
- **Very slow connection**: a page first shows what it has with a sign that more is coming. It
  never shows a half-received file as the whole file.
- **A Mac too old to know the new requests**: the phone falls back to today's read-only document,
  the reconstructed file and no terminal, and says the Mac needs updating. It never shows an empty
  pane with no reason.

## Requirements *(mandatory)*

### Functional Requirements

**Live pages**

- **FR-001**: The phone MUST show a Markdown file as a live page drawn from the file on disk, in the
  same page style as the Mac's and the phone's current document view.
- **FR-002**: A live page MUST update within a moment of the file changing on disk, whoever
  changed it, with no tap.
- **FR-003**: A live page MUST move to and briefly mark what changed, including a changed image.
  When a line is named, it MUST go to the passage holding that line.
- **FR-004**: When the agent of the conversation in front asks for a file to be shown, the phone
  MUST open it as the Mac does: a Markdown file as a live page, any other file in the file reader at
  the named line.
- **FR-005**: When the agent asks for a file to be shown and its conversation is not in front, or
  Alex is typing, the phone MUST NOT take the screen. It MUST offer the file in that conversation
  until it is opened or the moment has passed, as today.
- **FR-006**: Alex MUST be able to type into one passage at a time on a live page from the phone.
  The change MUST be written to the file on the Mac, and the Mac MUST record it as the person's, in
  the same way as a change typed on the Mac.
- **FR-007**: The agent's next turn MUST be told of changes typed on the phone, exactly as for
  changes typed on the Mac.
- **FR-008**: While a passage is open for typing, the agent's writes elsewhere MUST redraw around it
  and MUST NOT move the view or replace what is being typed. A collision on the same passage MUST be
  handled as on the Mac.
- **FR-009**: Text typed on the phone MUST NOT be lost because of a dropped connection. It MUST be
  saved when the connection returns, or kept on screen with a clear statement that it was not saved.

**Files**

- **FR-010**: The phone MUST let Alex browse the folder an agent is working in (its worktree when it
  has one), folders first, going into and back out of subfolders.
- **FR-011**: The listing MUST mark the files the agent has changed since it started, as the Mac's
  does.
- **FR-012**: The phone MUST show a text file's current contents with line numbers, and MUST show its
  new contents when it changes on disk while open.
- **FR-013**: The phone MUST show an image as a picture. It MUST say what any other non-text file is,
  and MUST show a very large text file in part, saying so.
- **FR-014**: Tapping a file named in a tool call MUST open the current file at the named line. What
  the agent did to that file MUST stay reachable from there.
- **FR-015**: The phone MUST be able to read only inside the folders the agent was given, the same
  boundary the Mac's pane and `show_file` use.
- **FR-016**: Files MUST remain read-only from the phone, apart from typing on a live page, as on the
  Mac.
- **FR-017**: A folder or file that disappears MUST be reported as gone, not left on screen as
  current.

**Terminal**

- **FR-018**: The phone MUST attach to the same per-agent shell the Mac's terminal pane uses, with
  its scrollback, and MUST NOT start a second shell for the same agent.
- **FR-019**: The terminal MUST pass typed input to the shell and show output as it is produced,
  including colour and cursor movement.
- **FR-020**: On a touch keyboard, the terminal MUST offer Control, Escape, Tab, the arrow keys and
  common shell symbols. On a hardware keyboard those keys MUST work directly.
- **FR-021**: The terminal MUST tell the shell the phone's size when it attaches and when it
  changes. When two devices share a shell, the size MUST follow the device that last typed.
- **FR-022**: The terminal MUST say when its shell has exited, failed to start or been let go, keep
  what it printed readable, and offer to start it again.
- **FR-023**: Nothing typed in the phone's terminal MUST reach the agent, and leaving the terminal or
  the app MUST leave the shell running on the Mac.

**Placement and continuity**

- **FR-024**: Each pane MUST be reachable from the conversation in at most two taps, on iPhone and
  iPad.
- **FR-025**: Where the screen fits the conversation at its reading width beside a pane, the pane
  MUST open as a column beside the conversation. Otherwise it MUST take the screen, with a way back
  that keeps the conversation's place.
- **FR-026**: The phone MUST remember, per agent, which pane was open and what it showed (page,
  folder, file and position), for as long as the app runs.
- **FR-027**: Exchanged entries that name a file in the agent's folder MUST open the live file. Entries
  that exist only in the conversation MUST open as they do today.

**Staleness and older Macs**

- **FR-028**: While the Mac is not answering, every pane MUST keep its last content, say it may be
  out of date, and disable typing on pages and in the terminal.
- **FR-029**: Against a Mac that does not offer these panes, the phone MUST fall back to today's
  read-only behaviour and say the Mac needs updating.

**Out of scope**

- **FR-030**: The browser pane MUST NOT be brought to the phone in this feature. Where the phone
  lists the panes, it MUST NOT show an empty or disabled Browser entry.

### Key Entities

- **Live page**: a Markdown file in an agent's folders, drawn as a document, following changes on
  disk and taking the person's typing one passage at a time. The same page on every device.
- **Folder listing**: what an agent's working folder holds at one moment, with the files the agent
  has changed marked.
- **File reading**: a file's current contents, or a statement of what it is when it cannot be shown
  as text, kept current while it is open.
- **Personal shell**: the person's own shell in an agent's folder, owned by the Mac, shared by every
  device looking at that agent, and outliving all of them.
- **Pane place**: per agent and per device, which pane is open and where in it the person was.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An agent's change to a shown Markdown file is visible on the phone's page within 2
  seconds on a normal connection, and the view is on it.
- **SC-002**: A paragraph typed on the phone is in the file on the Mac, and on the Mac's page, within
  2 seconds of Alex pausing. The agent's next turn is told of it in 100% of trials.
- **SC-003**: Any file inside an agent's folders can be opened from its phone chat in at most four
  taps, including folders two levels down.
- **SC-004**: The phone's terminal and the Mac's pane show the same session. A command started on
  one is visible running on the other, and survives the phone app being closed.
- **SC-005**: Control-C, Escape, Tab and the arrow keys can each be sent from an iPhone's touch
  keyboard in one tap.
- **SC-006**: A folder of 10,000 entries opens on the phone without the app becoming unresponsive.
- **SC-007**: Nothing possible today from the phone (the Exchanged list, a document read, what the
  agent did to a file, "look at this" offered in the chat) is lost.
- **SC-008**: In 20 edits made during connection drops, no typed text is lost without Alex being
  told.

## Assumptions

- The Mac is the reference for how each pane behaves. The page, the file reader and the shell are
  the same things the Mac shows, reached over the phone's existing connection to the Mac, not
  copies reconstructed on the phone.
- The phone reads files and folders only through the Mac, never directly. It is held to the same
  boundary as the agent's own `show_file`: the folders the agent was given.
- Typing on a live page from the phone goes through the same path as typing on the Mac's page, so
  the agent is told of it in the same way. There is no second mechanism.
- The phone's shell is the Mac's existing per-agent shell (002). Its lifetime, idle release and
  "the person's, not the agent's" rule are unchanged.
- The phone keeps a pane's place for as long as the app runs. Places are not carried across a
  relaunch or between devices.
- "Look at this" from an agent opens in front only when the conversation is in front and Alex is not
  typing. Otherwise it is offered, as 013 decided for the phone.
- The browser stays at the Mac (Alex, 2026-09-24). A later feature may carry the Mac's local pages to
  the phone.
- 033 (one chat on every screen) is building the chat these panes open from. This feature assumes
  its top bar and prompt area, and changes neither. 033's deliberate difference, "opening a touched
  file shows what the agent did in a sheet", is replaced here by opening the current file, with what
  the agent did one tap away.
- The phone and iPad walks are Alex's. This Mac cannot tap a simulator.
