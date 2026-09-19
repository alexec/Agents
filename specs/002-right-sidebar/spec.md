# Feature Specification: The right sidebar

**Feature Branch**: `002-right-sidebar`

**Created**: 2026-09-18

**Status**: Draft

**Research**: what ACP gives a client to follow along with, verified against the v1
schema and this app's own stored transcripts on 2026-09-18. See the note under Artifacts.

**Input**: User description: "I'd like to add support for right sidebar. It'll contain a terminal, file browser, web browser, and artifacts."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See what the agent is doing to the folder (Priority: P1)

The agent says it edited three files. The user opens the sidebar on the right of the conversation,
sees the folder the agent is working in, and reads one of those files without leaving the window or
opening an editor. The files that changed since the agent started are the ones that stand out.

**Why this priority**: Reading the agent's own account of its work is not the same as reading the
work. This is the first reason to look right instead of down, and it carries the sidebar frame with
it: opening it, sizing it, putting it away.

**Independent Test**: Start an agent on a task that edits a file, open the sidebar, find the file it
named, and read the new contents. Delivers the whole of the feature's value on its own.

**Acceptance Scenarios**:

1. **Given** an agent is selected, **When** the user opens the sidebar, **Then** it appears to the
   right of the conversation showing the agent's folder, and the conversation stays usable beside it.
2. **Given** the sidebar is open, **When** the user chooses a file, **Then** its contents appear in
   the sidebar within 1 second for a file of ordinary size.
3. **Given** the agent writes to a file while the user is reading it, **When** the write lands,
   **Then** the sidebar shows the new contents without the user asking for them.
4. **Given** the sidebar is open on one agent, **When** the user switches to another agent, **Then**
   the sidebar shows that agent's folder, and coming back shows what was open before.
5. **Given** the sidebar is open, **When** the user closes it and reopens the app, **Then** it is
   still closed, and opening it returns to the pane that was last showing.

---

### User Story 2 - Run something yourself, in the same folder (Priority: P1)

The agent claims the tests pass. The user opens the terminal pane and runs them. The shell starts in
the agent's folder, so there is nothing to type to get there.

**Why this priority**: Checking the agent is the other half of watching it. Today that means a
separate terminal app, finding the folder again, and losing which window belongs to which agent.

**Independent Test**: Open the terminal pane on a running agent, run a command that prints the
working folder, and see the agent's folder. Run a build and watch it scroll.

**Acceptance Scenarios**:

1. **Given** an agent is selected, **When** the user opens the terminal pane, **Then** a shell is
   ready in that agent's folder within 2 seconds.
2. **Given** a command is running, **When** it produces output, **Then** the output appears as it is
   produced, and the user can interrupt it the way they would in any terminal.
3. **Given** a command asks a question, **When** the user types an answer, **Then** the program
   receives it, including for programs that take single keypresses rather than lines.
4. **Given** the user moves to another pane and back, **When** the terminal reappears, **Then** the
   same session is still there with its scrollback and anything still running.
5. **Given** two agents in different folders, **When** the user opens the terminal on each, **Then**
   each has its own shell in its own folder and neither sees the other's history.
6. **Given** a build is running in the terminal, **When** the user quits the app and opens it again,
   **Then** the build is still running and the output it produced in between is there.

---

### User Story 3 - Look at what the agent built (Priority: P2)

The agent started a dev server, or wrote a page, or pointed at documentation. The user opens the
browser pane, types or follows the address, and looks at it beside the conversation.

**Why this priority**: Front-end work is unverifiable without it. It matters less than files and a
shell because a real browser is one command away, but that browser is never beside the conversation.

**Independent Test**: With a local server running in the agent's folder, open the browser pane, go
to the address, and see the page. Change a file, reload, see the change.

**Acceptance Scenarios**:

1. **Given** the browser pane is open, **When** the user enters an address, **Then** the page loads
   in the sidebar with a way to go back, forward and reload.
2. **Given** a page is loaded, **When** the user switches agents and comes back, **Then** the same
   page is still showing.
3. **Given** an address that cannot be reached, **When** the load fails, **Then** the pane says what
   failed and offers to try again, rather than showing a blank panel.
4. **Given** a page the user is signed into in Safari, **When** they open it here, **Then** this
   browser does not carry Safari's cookies or passwords, and says nothing about them.

---

### User Story 4 - Keep the things worth keeping (Priority: P2)

A long conversation buries what came out of it. The artifacts pane holds the things the agent
produced that are worth coming back to, in one list, away from the messages they arrived in.

**Why this priority**: It is the pane whose absence is least felt on day one and most felt at hour
three. It also depends on the others existing: an artifact is opened in the file pane or the browser.

**Independent Test**: Run an agent until it has produced several artifacts, open the pane, and find
one of them without scrolling the conversation.

**Acceptance Scenarios**:

1. **Given** an agent has produced artifacts, **When** the user opens the artifacts pane, **Then**
   each is listed with what it is and when it arrived, newest first.
2. **Given** an artifact in the list, **When** the user chooses it, **Then** it opens where it can be
   read, and the user can get to the message it came from.
3. **Given** an agent that has produced nothing yet, **When** the user opens the pane, **Then** it
   says what will appear there rather than showing an empty box.
4. **Given** an artifact is produced while the pane is open, **When** it arrives, **Then** it appears
   in the list without the user asking.

---

### Edge Cases

- No agent is selected, because the user is on the start form. The sidebar has no folder to show, so
  it says so, or it is not offered at all.
- The agent's folder is deleted, renamed or moved while the sidebar is open on it.
- A file the user is reading is deleted by the agent.
- The user chooses a file that is very large, or binary, or not text at all.
- A folder with many thousands of entries. The pane stays responsive and the user can still find a
  file.
- A command in the terminal is still running when the user closes the window or quits the app.
- A command is running when the Mac restarts, which takes the daemon with it.
- A shell sits idle for days with nothing running in it.
- A command in the terminal deletes the folder the shell is sitting in.
- The shell the user's Mac is configured with fails to start, or does not exist.
- The user runs an agent runtime inside the terminal pane. Allowed, and nothing here pretends it is
  one of this app's agents.
- A page in the browser pane tries to download a file, open a window, or ask for the camera.
- The browser pane is pointed at a local server that the agent then stops.
- An artifact refers to a file that has since been changed or deleted.
- Two windows are open on the same agent. Each has its own sidebar, and both look at the one shell
  that agent has, because the shell belongs to the agent rather than to a window.
- The window is narrow. The sidebar and the conversation cannot both be usable, and the app has to
  choose.
- An agent is archived. Its folder, its artifacts and a shell in that folder are all still reachable
  or the pane says why not.

## Requirements *(mandatory)*

### Functional Requirements

**The sidebar**

- **FR-001**: The system MUST offer a sidebar on the right of the conversation, holding four panes:
  files, terminal, browser and artifacts.
- **FR-002**: The sidebar MUST belong to the selected agent: what it shows is that agent's folder and
  that agent's artifacts, and switching agents switches what it shows.
- **FR-003**: Users MUST be able to open and close the sidebar, and to change its width, with the
  conversation keeping the rest of the window.
- **FR-004**: The system MUST remember whether the sidebar is open, how wide it is, and which pane
  was showing, across quitting and reopening the app.
- **FR-005**: The system MUST remember per agent what each pane was showing, so that returning to an
  agent returns to where the user left off in it.
- **FR-006**: The sidebar MUST NOT be required to use the app. Everything in feature 001 stays
  reachable with the sidebar closed.
- **FR-007**: The sidebar MUST say why it is empty when no agent is selected, rather than showing
  four blank panes.

**Files**

- **FR-010**: The files pane MUST show the folder the selected agent is working in, and let the user
  move through it.
- **FR-011**: Users MUST be able to read the contents of a text file in the pane.
- **FR-012**: The pane MUST show a file's new contents when it changes on disk, without the user
  asking.
- **FR-013**: The pane MUST show which files have changed since the agent started, so the agent's
  work is findable without reading the conversation.
- **FR-014**: The pane MUST say what a file is when it cannot be read as text, rather than showing
  its bytes.
- **FR-015**: The pane MUST stay responsive in a folder with many thousands of entries, and MUST NOT
  read a whole large file to show the start of it.
- **FR-016**: The pane MUST say what happened when the folder or a file it is showing disappears, and
  MUST NOT leave stale contents on screen as though they were current.
- **FR-017**: This feature MUST NOT let the user edit files from the pane. Reading is the whole of it.

**Terminal**

- **FR-020**: The terminal pane MUST give the user an interactive shell whose working folder is the
  selected agent's folder, started with the shell the user's Mac is configured with.
- **FR-021**: The terminal MUST behave as a terminal: output as it is produced, input including
  single keypresses, interrupt, and the screen handling that full-screen programs expect.
- **FR-022**: The terminal MUST keep its session and scrollback while the user moves between panes
  and between agents.
- **FR-023**: Each agent MUST have its own shell, and one agent's terminal MUST NOT show another's
  history. Two windows open on the same agent MUST see the same shell rather than one each.
- **FR-024**: The terminal MUST say when its shell has exited or failed to start, and MUST let the
  user start a new one.
- **FR-025**: The shell MUST be the user's own, not the agent's. What the agent runs is shown in the
  conversation, and nothing the user types here goes to the agent.
- **FR-026**: A shell MUST outlive the window the way an agent does. A command still running when the
  user closes the window or quits the app MUST keep running, and MUST be found still running, with the
  output produced in between, when a window opens on that agent again.
- **FR-027**: The system MUST count a shell with something running in it as work it is holding, and
  MUST NOT shut down underneath it.
- **FR-028**: The system MUST let go of an idle shell rather than keeping one alive for every agent
  forever, and MUST say when a shell has been let go rather than showing a dead one as live.
- **FR-029**: The system MUST mark a shell as gone, with the reason, when it dies with the machine or
  with the process that owned it, and MUST keep what it printed readable.

**Browser**

- **FR-030**: The browser pane MUST load a web address the user enters, and MUST offer back, forward
  and reload.
- **FR-031**: The pane MUST keep the page it is showing when the user moves between panes and between
  agents.
- **FR-032**: The pane MUST say what failed when a page cannot be loaded, and MUST offer to try again.
- **FR-033**: The browser MUST keep its own session. It MUST NOT read or write Safari's cookies,
  history or passwords.
- **FR-034**: The pane MUST NOT let a page open windows of its own, and MUST ask the user before
  anything a page does reaches the Mac beyond the page itself.
- **FR-035**: This feature MUST NOT give the agent control of the browser. The user drives it.

**Artifacts**

- **FR-040**: The artifacts pane MUST list what the selected agent has produced that is worth keeping,
  newest first, each with what it is and when it arrived.
- **FR-041**: The list MUST update as artifacts arrive, without the user asking.
- **FR-042**: Users MUST be able to open an artifact and read it, and to get from it to the message it
  came from.
- **FR-043**: The pane MUST say what will appear there when the agent has produced nothing yet.
- **FR-044**: The system MUST keep an agent's artifacts for as long as it keeps its history, including
  across the app and the daemon restarting, and MUST keep them readable for a stopped or archived
  agent.
- **FR-045**: The pane MUST say so when an artifact points at something that has since changed or gone,
  rather than showing what is no longer there.
- **FR-046**: [NEEDS CLARIFICATION: what counts as an artifact? Every file the agent created or
  changed, only the things the runtime itself marks, or things the user keeps by hand?]

What the protocol offers here, checked against the v1 schema and this app's own transcripts on
2026-09-18:

- A tool call carries `locations`, a list of file paths with optional line numbers, described in the
  protocol as what a client needs for follow-along. Seen in real transcripts from claude and copilot.
- A tool call's content can be a `diff`, with the path, the old text and the new text. Seen from both.
- A content block can be a `resource_link` (a uri with a name, a title, a mime type and a size) or an
  embedded `resource`, and either can carry annotations saying the audience is the user and how
  important it is. Nothing has sent one of these here yet.
- A tool call's content can embed a terminal the client created. Closed off for now: the app tells
  every runtime it serves no file or terminal methods, so the runtimes use their own tools.

So there is no "show this to the user" verb. There is a reliable feed of which files a tool call
touched and what it changed them to, and an unused route for an agent to hand over a named thing.

### Key Entities

- **Sidebar state**: What the sidebar is showing for one agent: whether it is open, how wide, which
  pane, and where each pane had got to. Belongs to a window and an agent, not to the daemon.
- **Terminal session**: One shell running in one agent's folder, with its scrollback and whatever it
  is running. Belongs to one agent.
- **Artifact**: Something an agent produced that is worth coming back to. Has what it is, when it
  arrived, the message it came from, and where to find it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can go from an agent saying it changed a file to reading that file in under 10
  seconds, without leaving the window.
- **SC-002**: A file changed by the agent shows its new contents in the sidebar within 2 seconds of
  the change landing on disk.
- **SC-003**: A shell is ready to type into within 2 seconds of the terminal pane being opened, in a
  folder of any size.
- **SC-004**: A user can check the agent's claim that the tests pass without opening another app.
- **SC-005**: Switching between ten agents with the sidebar open leaves the window responsive, and
  each agent comes back to the pane and position it was left at.
- **SC-006**: Nothing running in a terminal is lost by moving between panes or agents: output
  produced while the pane was hidden is all there when it comes back.
- **SC-007**: A user working on a page can see their change in the browser pane within one reload,
  without switching applications.
- **SC-008**: After an hour-long conversation, a user finds any artifact the agent produced in under
  15 seconds, without scrolling the conversation.
- **SC-010**: A build started in the terminal and still running when the app is quit is still running
  60 seconds later, and all its output is there when a window opens on that agent again.
- **SC-009**: Closing the sidebar returns the window to exactly the behaviour of feature 001, with no
  step added to starting, following up or stopping an agent.

## Assumptions

- The sidebar is the user's, not the agent's. The agent has its own tools and its own terminal; these
  panes are for the person watching.
- The panes are read and run, not edit. Editing files, staging changes and committing belong to a
  later feature, and the terminal is the escape hatch until then.
- Only one pane is visible at a time. The sidebar is one column, and the four panes take turns in it.
- The browser is a viewing surface for local servers and documentation, not a replacement for Safari.
  No tabs, no bookmarks, no downloads in this feature.
- The sidebar belongs to the window, and the shell inside it does not. Two windows on the same agent
  each get their own sidebar, and both look at that agent's one shell, which the daemon holds for the
  same reason it holds agents: a build that dies when a window closes is a build you cannot start
  before lunch.
- Terminal history is not agent history. The daemon records what the agent did, and what the user
  typed into a shell is not part of that record.
- One person, one Mac, as in feature 001. Anything running in the terminal runs as the user, with the
  access the user has.
- Reading a file means reading what is on disk now. This feature does not show the history of a file
  or what it looked like before the agent touched it.
