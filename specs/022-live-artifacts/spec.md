# Feature Specification: Live Artifacts, A Proof Of Concept

**Feature Branch**: `022-live-artifacts`

**Created**: 2026-09-21

**Status**: Draft — amended 2026-09-21 for images beside the document (User Story 4, FR-019–FR-020, SC-008), and again the same day so that nothing the agent is given changes but one sentence (FR-007)

**Input**: User description: "Live artifacts, proof of concept. A live artifact is a document the person or the agent can edit and the changes appear live, very much like Google Docs: you can see the changes the agent makes in real time, and the window follows the agent about. Simple Markdown documents to start with — this is a PoC to find out what tools we need to create for the agent. Decided already: the artifact is a Markdown file on disk in the project, the agent edits it with its ordinary edit/write tools and the app watches the folder and redraws; new app tools are only for attention (open this artifact, follow me to this place). The person edits the rendered page in place, plain text on the paper surface, with live re-rendering when the agent writes."

## Why this feature exists

Most of what an agent produces here is a document: a spec, a plan, a set of notes, a
README. Today the person reads it after the fact — they open the file when the agent says
it is done, or they watch a diff scroll past in the conversation and reconstruct the
document in their head. Writing together does not happen at all. If the person wants a
paragraph changed they say so in the chat, wait for the turn, and open the file again.

What is wanted is the thing two people have when they share a document: the page is open,
the other's changes appear in it as they are made, the view goes to where the work is, and
either of them can just type. Not a review step, a shared page.

This is a proof of concept, and it has one job beyond working: to find out what an agent
needs to be given to take part in that. The decisions that could be made in advance have
been. The artifact is an ordinary Markdown file in the project folder; the agent changes it
with the tools it already has for changing files; the app watches and redraws. What is not
known is what else the agent reaches for once the page is live — how it asks for the
person's attention, how it learns what the person changed under it, what it does when the
two of them are in the same paragraph — and the way to find out is to build the page and
watch.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Watch the agent write (Priority: P1)

The person asks an agent to draft a document. A page opens beside the conversation and the
document appears on it as the agent writes: a heading, then a paragraph under it, then a
list, each change drawn within a moment of being made. The view goes to where the agent is
working — when it adds a section at the bottom, the page scrolls to the bottom; when it goes
back and rewrites the introduction, the page goes back to the introduction — and what just
changed is briefly marked, so the eye finds it. The person never touches the file and never
refreshes anything.

**Why this priority**: This is the feature. A page that shows the agent's work as it
happens, and follows it, is the whole of the value on its own, and it is the half that
needs no new editing surface to prove.

**Independent Test**: Ask an agent to write a short document in three or four steps. The
page opens when the agent begins, every step appears on it without the person doing
anything, and the view is on the most recent change each time.

**Acceptance Scenarios**:

1. **Given** a conversation is open and no artifact is showing, **When** the agent begins
   writing a Markdown document and asks for it to be shown, **Then** the page opens beside
   the conversation with that document rendered on a paper surface.
2. **Given** the page is open on a document, **When** the agent changes the file, **Then**
   the page shows the new content within a moment, rendered, without the person acting.
3. **Given** the page is open and the agent changes one part of a long document, **When**
   the change lands, **Then** the view moves so the changed part is on screen, and the
   changed part is marked briefly so it can be told from what was already there.
4. **Given** the agent makes several changes in quick succession, **When** they land,
   **Then** the page shows the final state without flicker, missed steps, or a stale
   version drawn after a newer one.
5. **Given** the page is open, **When** the agent asks for the person to look at a
   particular line of the document, the way it already can for any file, **Then** the
   view goes to the passage that holds that line and marks it, whether or not it just
   changed — the page stays a page, and does not turn into numbered source.
6. **Given** the person has scrolled away to read something else, **When** the agent
   makes a change elsewhere, **Then** the view still follows the agent — this is the
   proof of concept's rule, and whether it should be softer is one of the things it exists
   to find out.

---

### User Story 2 - Type on the same page (Priority: P2)

The page the agent is writing on is also the page the person edits. They click into a
paragraph and type; the words go into the document, and the document on disk soon holds
them. They do not switch to a source view, they do not save, and they do not lose their
place. When the agent next writes, the person's words are still there, and the agent's
change appears around them.

**Why this priority**: Without this the page is a viewer, not a shared document. It comes
second because it is the harder half — editing on a rendered page, while somebody else is
also writing to the file — and because the first story is worth having on its own.

**Independent Test**: With the agent idle, type a sentence into an open artifact and
confirm the file on disk holds it within a couple of seconds. Then, with the agent
rewriting a different section, type another sentence and confirm both survive on disk and
on the page.

**Acceptance Scenarios**:

1. **Given** an artifact is open on the page, **When** the person clicks into the text and
   types, **Then** the characters appear where they typed, on the rendered page, with no
   separate editing mode to enter.
2. **Given** the person has typed, **When** they pause, **Then** the document on disk holds
   what they typed, without them saving.
3. **Given** the person is typing in one part of the document, **When** the agent changes a
   different part, **Then** the agent's change appears, the person's text remains where it
   was, their insertion point does not jump, and the file on disk ends up holding both.
4. **Given** the person has typed and the agent then changes the very passage they were
   typing in, **When** the two collide, **Then** nothing the person typed disappears
   silently: their text is kept, and the page tells them plainly that the agent's version of
   that passage was set aside for them to look at.
5. **Given** the person is editing, **When** the agent makes a change elsewhere, **Then**
   the view does not leave the place where they are typing.
6. **Given** the person edits the file in some other program while the page is open,
   **When** they save there, **Then** the page shows it, the same as it would an agent's
   change.

---

### User Story 3 - The agent knows what the person changed (Priority: P3)

The person rewrites a paragraph on the page. The agent, when it next acts, knows that the
document changed under it and where, rather than working from the version it last wrote,
and it can carry on from the person's words instead of overwriting them.

**Why this priority**: This is the direction nothing goes today: the agent's changes reach
the person, and the person's changes reach the file, but nothing tells the agent. It is
third because it is the least certain how it should be done, which makes it the thing the
proof of concept most needs to try rather than decide.

**Independent Test**: Edit a paragraph on the page, then ask the agent to continue the
document. Its next change builds on the edited paragraph rather than the one it wrote.

**Acceptance Scenarios**:

1. **Given** the person has changed an open artifact since the agent last wrote to it,
   **When** the agent next takes a turn, **Then** the agent knows the document changed and
   which part, before it writes anything.
2. **Given** the agent has been told of the person's change, **When** it writes, **Then** it
   does not restore the version the person replaced.
3. **Given** the person changed the document while the agent was mid-turn, **When** the
   agent next writes to the file, **Then** the person's change is not lost — either the
   agent's write includes it, or the collision is handled as in the second story.

---

### User Story 4 - Pictures on the page (Priority: P4)

The agent puts a diagram in the document: it writes an SVG file beside it and references it
the ordinary way. The picture appears on the page where the reference is, and when the agent
redraws the file the picture changes on the page and is marked, the same as a changed
paragraph. A graph is a picture too: the agent draws it as an SVG.

**Why this priority**: A document that cannot hold a picture is a document the agent will
leave to write somewhere else. Fourth because the page must exist and be typed on first, and
because images already render — what is missing is the mark.

**Independent Test**: Ask the agent for a document with one SVG diagram. It appears on the
page; ask the agent to redraw it; the picture changes and is marked.

**Acceptance Scenarios**:

1. **Given** the document references an image file beside it, **When** the page renders,
   **Then** the image appears at the reference, sized to the page's width, and an SVG is
   drawn as a picture rather than shown as text.
2. **Given** an image is showing on the page, **When** the agent rewrites the image file
   without touching the document's text, **Then** the picture on the page changes within a
   moment and is marked, and the view goes to it the same as to a changed paragraph.
3. **Given** a referenced image is missing or unreadable, **When** the page renders,
   **Then** its alternative text is shown in its place, and the page carries on.

---

### User Story 5 - The proof of concept says what it learned (Priority: P5)

At the end, there is a short written record of what the agent reached for and could not do,
what it was given and did not use, and what the page needed that a plain file did not
provide. That record is the input to the real feature.

**Why this priority**: The stated reason for the proof of concept is to find out what tools
the agent needs. Building the page without writing this down would answer the question and
then lose the answer.

**Independent Test**: The record exists, names each candidate tool or mechanism, and for
each says what was observed that made it necessary or unnecessary.

**Acceptance Scenarios**:

1. **Given** the first four stories have been exercised with at least two of the known
   runtimes, **When** the proof of concept is closed, **Then** a findings document lists
   every attention or coordination capability the agent used, needed, or was missing, with
   the observation behind each.
2. **Given** a capability was tried and not needed, **When** it is recorded, **Then** the
   record says so rather than leaving it out, so it is not proposed again.

---

### Edge Cases

- The file the agent is writing does not exist yet when it asks for it to be shown. The
  page opens empty with the file's name, and fills when the file appears.
- The agent deletes or renames the file while the page is open. The page says the document
  is gone and keeps the last content it had, so nothing the person typed is lost.
- The agent writes something that is not Markdown, or is Markdown the renderer cannot
  draw. The page falls back to showing the text plainly rather than a blank page.
- The document is large — thousands of lines. The page still follows the agent and still
  takes typing, and the moment-to-redraw budget holds for documents up to the size the
  files pane already shows.
- The person's typing and the agent's write land in the same instant. The person's text is
  kept; see the second story's collision scenario.
- The agent is stopped or crashes mid-write, leaving a half-written file. The page shows
  what is on disk and does not pretend the document is finished.
- Two conversations in the same project have the same file open. Each page follows its own
  conversation's agent, and both show every change to the file.
- The person closes the page while the agent is still writing. Nothing is lost: the file
  is the document, and opening the page again shows the current state.
- The agent asks for attention on a file outside the folders it was given. Refused, the
  same as showing any other file.
- The document references an image outside the project folder, or by a web address. Not
  fetched: its alternative text is shown, as the conversation already does.
- An image is very large. It is scaled to the page's width and never past its own size.

## Requirements *(mandatory)*

### Functional Requirements

**The page**

- **FR-001**: An artifact MUST be an ordinary Markdown file within the project folder.
  There is no second store, and nothing about the file marks it as an artifact: any Markdown
  file may be opened as one.
- **FR-002**: The page MUST show the artifact rendered as a document on the paper surface
  the app already has, and MUST sit beside the conversation the agent is in.
- **FR-003**: The page MUST show a change to the file on disk, from any writer, within a
  moment of it landing, and MUST keep the person's place unless a rule below moves it.
- **FR-004**: A run of changes in quick succession MUST end with the page showing the
  newest content; an older version MUST never be drawn after a newer one.
- **FR-005**: The page MUST mark what most recently changed, briefly, so the change can be
  told from what was already there. The mark MUST fade on its own.

**Following the agent**

- **FR-006**: When the agent changes the file, the view MUST move to bring the changed part
  on screen, unless the person is typing (FR-013).
- **FR-007**: The agent MUST be able to ask for an artifact to be opened on the page, and
  to name a line in it, using exactly the request it already has for showing any file:
  nothing new is added to what the agent is given, and no argument changes. A named line
  on a Markdown file MUST take the view to the passage holding that line and mark it,
  rather than switching the page to numbered source. The only agent-facing change here is
  the wording of that request's description, which MUST say that a Markdown file opens as
  a live page that follows the agent's edits.
- **FR-008**: An artifact the agent asks to open MUST be inside the folders the agent was
  given, or the request MUST be refused and the agent told so.
- **FR-009**: A request to open an artifact in a conversation the person is not reading
  MUST wait until they open it, the same as a file shown today.

**Typing on the page**

- **FR-010**: The person MUST be able to place an insertion point in the rendered document
  and type, with no separate mode to enter. The proof of concept's editing is plain text:
  what the person types is written into the file as Markdown as typed, and the page
  re-renders it.
- **FR-011**: What the person types MUST reach the file on disk without an explicit save,
  within a short pause after they stop typing.
- **FR-012**: A change from the agent that lands while the person has typed something not
  yet on disk MUST be combined with the person's text when the two are in different parts
  of the document, and MUST NOT move the person's insertion point.
- **FR-013**: While the person is typing, an agent's change MUST NOT scroll the view away
  from them. Following resumes when they stop.
- **FR-014**: When the agent's change and the person's unsaved text are in the same passage,
  the person's text MUST be kept, and the page MUST say what happened and show the agent's
  version of that passage rather than discarding it.
- **FR-015**: Nothing the person typed MUST ever be lost without the page saying so.

**Telling the agent**

- **FR-016**: Before an agent writes to an artifact the person has changed since the agent
  last wrote it, the agent MUST have been told that the document changed and which part.
  How it is told is for the plan; that it is told is required.

**Pictures**

- **FR-019**: An image referenced by a relative path from the document MUST render at the
  reference, scaled to the page's width and never past its own size. SVG MUST draw as a
  picture. An image by web address or outside the project folder MUST NOT be fetched, and
  its alternative text MUST be shown instead.
- **FR-020**: When a referenced image file changes on disk while the page is open, the
  picture MUST update within a moment and be marked, and the view MUST go to it under the
  same rules as a changed passage (FR-005, FR-006, FR-013).

**What this is for**

- **FR-017**: The proof of concept MUST end with a findings document in the feature folder
  that names each capability the agent used, needed, or was missing, with the observation
  behind each, and MUST have been exercised with at least two of the known runtimes.
- **FR-018**: The proof of concept MUST NOT change the conversation, the files pane's
  listing, the remotes, or any runtime's tool policy beyond what the attention request in
  FR-007 needs.

### Key Entities

- **Artifact**: A Markdown file in the project folder, open on the page beside a
  conversation. Identified by its path. It has no existence apart from the file.
- **Change**: One landing of new content on the page: who made it (the agent of this
  conversation, the person on the page, or something else), which part of the document it
  touched, and when. Changes are what the page marks and follows, and what the agent is
  told about.
- **Attention request**: The agent asking for an artifact to be opened, or for a place in
  it to be looked at. Carries the path and, optionally, a place.
- **Findings**: The written record the proof of concept produces: capabilities observed,
  needed, missing, or unused, each with its evidence.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A change the agent makes to an open artifact is visible on the page within
  one second of landing on disk, for documents up to the size the files pane shows today.
- **SC-002**: Across a document written by an agent in twenty or more separate changes,
  the page ends on the final content every time, and a reader watching can name the part
  that changed at each step without being told.
- **SC-003**: Text the person types on the page is on disk within two seconds of them
  pausing, in every case tried.
- **SC-004**: Over fifty alternating edits — person and agent, different parts of the
  document — no character either of them wrote is missing from the final file, and the
  person's insertion point never moved on its own.
- **SC-005**: When the person and the agent change the same passage, the person's text
  survives in the file every time, and the page told them what happened every time.
- **SC-006**: After the person edits a paragraph, the agent's next write builds on the
  edited paragraph rather than the one it wrote, in at least nine of ten trials with each
  runtime tried.
- **SC-007**: The findings document exists and names every capability tried, with a
  one-line observation for each; a reader who did not watch the proof of concept can say
  from it which tools the real feature needs.
- **SC-008**: An agent asked for a document with a diagram produces one on the page as an
  SVG beside it without being told how, in at least four of five trials with each runtime
  tried; and a redraw is visible and marked within one second of landing.

## Assumptions

- The page is the sidebar surface the files pane already uses, rendered with the
  document view the app already has. Whether a document wants a wider, separate window is
  one of the things to find out by running it, not a decision to make first.
- Editing on the rendered page is plain-text editing: the person types Markdown as
  Markdown. Formatting controls and rich selection are out of scope. Images are files the
  agent writes beside the document; inserting one from the page is out of scope.
- Graphs and diagrams are pictures the agent draws as SVG files. Nothing is drawn from
  data by the page. Diagram languages that need a renderer of their own — Mermaid first
  among them — are not built; whether agents reach for one anyway is a finding.
- The agent's changes arrive as whole-file writes, because that is what its ordinary edit
  and write tools do. Which part changed is worked out by comparing versions. Finer-grained
  operations are not built; if the findings say they are needed, that is a finding.
- "The agent" whose changes the page follows is the agent of the conversation the page sits
  beside. Other writers' changes are shown but not followed.
- The Mac window only. The iPad and iPhone remotes do not get the page in this proof of
  concept.
- Files the pane already declines to show — too large, not text — are not artifacts.
- The existing rule that an agent may only reach inside the folders it was given applies
  unchanged to artifacts.
- Undo on the page is the platform's ordinary text undo; undoing an agent's change is out
  of scope.
- The proof of concept is throwaway in the sense the paper document view was: what it
  proves is kept, and whatever it is built from may be rebuilt for the real feature.
