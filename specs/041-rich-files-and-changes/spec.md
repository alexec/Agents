# Feature Specification: Code That Reads Like Code, in Files and Changes

**Feature Branch**: `041-rich-files-and-changes`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Rich files and changes. The changes/diff view has landed but both that and the existing file views are not very rich. It often needs to be richer. I'm not sure the best way to do this. It must be a careful balance between performance, simplicity, library use, system libs. We should support common coding file types. Perhaps there is a library to make this easy?"

## Why this feature exists

The app now shows code in four places: the files pane, the Changes pane (035), each edit in the
conversation, and code blocks in messages and pages. In all four, code is a column of plain
monospaced text. That is enough to prove a file exists. It is not enough to read one.

What is missing, seen on 2026-09-25 in the running app:

- **No structure in the text.** A Swift file, a JSON file and a shell script look the same. The
  eye cannot find where a string ends, which line is a comment, or where a function starts,
  without reading every character. Every code editor the person uses does this for them.
- **An edit is not a diff.** An edit is drawn as every old line struck through, then every new
  line. Change one word on line 3 of a 40-line passage and the person reads 80 lines to find it.
  Nothing says which lines are unchanged and nothing says which words moved.
- **Whole file shows everything or nothing.** A 900-line file with two changed lines is 900 lines
  to scroll through to find them.
- **The places disagree.** The files pane numbers and wraps its lines, edits scroll sideways and
  have no numbers, code blocks in messages have neither.

This feature makes code in all four places read like code: coloured by what it is, with changes
shown as a real diff down to the word, unchanged stretches folded away, and the same look
wherever it appears, on the Mac, the phone and the iPad.

### The balance

Rich must not mean slow, heavy or fragile. The app is opened on files an agent is writing as the
person watches, on a phone over the network, and on generated files thousands of lines long. So
this feature sets limits alongside its features: how fast a file appears, how much the app grows,
what happens to a language it does not know, and what happens past a size where colour is not
worth what it costs (FR-016 to FR-020, SC-001 to SC-005). It does not bring in a code editor, a
web view or anything that needs the network.

## Clarifications

### Session 2026-09-25

- Q: 035 keeps colour for something having gone wrong and shows change by mark and weight. How far
  should colour go? → A: Syntax colour, not diff colour. Code is coloured by what it is, in a
  quiet palette drawn from the theme; added and removed lines keep their marks, weight and at most
  a faint tint, never red and green (FR-004, FR-011).
- Q: Which devices? → A: Mac, phone and iPad. The views are shared already (FR-021).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A file reads like code (Priority: P1)

An agent names a Swift file with `show_file`. It opens in the files pane with keywords, strings,
comments, numbers and types each set apart, in colours that sit quietly in the Paper, Light or
Dark theme the person has chosen. The person finds the comment the agent pointed at without
reading every line. They open `package.json` next, then a shell script, then a Markdown file's
fenced Python block; each is coloured for what it is.

**Why this priority**: The files pane is where the person reads most code in the app, and it is
the change every other story builds on: an edit or a code block is coloured the same way.

**Independent Test**: Open one file of each common kind (FR-002) in the files pane. Each is
coloured for its language; a file of an unknown kind opens plain, promptly and with no message
about it.

**Acceptance Scenarios**:

1. **Given** a Swift file, **When** it opens in the files pane, **Then** keywords, strings,
   comments, numbers and type names are each shown distinctly, and line numbers are unchanged.
2. **Given** a file whose kind the app does not know, **When** it opens, **Then** it shows as
   plain text, exactly as today, with no error.
3. **Given** the person switches between Paper, Light and Dark, **When** a coloured file is open,
   **Then** its colours follow the theme and every colour stays readable against its background.
4. **Given** a coloured file, **When** the person selects and copies lines, **Then** what is
   copied is the plain text, with no colour, marks or line numbers.
5. **Given** a file an agent is still writing, **When** it changes, **Then** the new text is
   coloured as it arrives, and the reader's place is kept as it is today.

---

### User Story 2 - An edit shows what changed, not everything (Priority: P1)

The agent changed one word on one line of a 40-line passage. In the conversation and in the
Changes pane, the edit now shows the lines around it unchanged and plain, the one line that went
and the one that came, and within them the word that changed marked more strongly than the rest.
The person sees the change in the time it takes to find one line.

**Why this priority**: This is the question 035 set out to answer ("is that right?"). A diff
that makes the person hunt for the change answers it slowly.

**Independent Test**: Have a Claude agent change a single word in the middle of a long passage.
The edit shows a few unchanged lines, one removed line, one added line, and the changed word
marked within each. Compare with a pure addition (a new function): only added lines, no removed.

**Acceptance Scenarios**:

1. **Given** an edit whose old and new text share most lines, **When** it is shown, **Then** the
   shared lines appear once, unmarked, and only differing lines are marked removed or added.
2. **Given** a removed line and the added line that replaced it, **When** they differ by a few
   words, **Then** those words are marked within each line, more strongly than the line's own
   mark.
3. **Given** a long unchanged run inside an edit, **When** it is shown, **Then** it is folded to a
   few lines of context either side and a line saying how many are hidden, which opens it.
4. **Given** an edit that made a new file, **When** it is shown, **Then** every line is marked
   added and none is hidden, as today.
5. **Given** a changed line, **When** it is shown, **Then** it is still coloured as code, with the
   change marks laid over the colour rather than replacing it.

---

### User Story 3 - Whole file goes straight to what changed (Priority: P2)

A 900-line file with two changes in it. The person switches to Whole file. They see the first
change with a few lines either side, a fold saying 400 lines are hidden, the second change, and a
fold for the rest. They can open any fold, and they can step from one change to the next without
scrolling for it.

**Why this priority**: Whole file is how the person sees the file as it stands. Today it gives
them the whole file to scroll; this gives them the changes first and the file on request.

**Independent Test**: In a git project, have an agent change two lines far apart in a long file.
Whole file shows both changes with folds between them; stepping to the next change moves to the
second.

**Acceptance Scenarios**:

1. **Given** a Whole file view with changes far apart, **When** it opens, **Then** long unchanged
   runs are folded, each fold saying how many lines it hides.
2. **Given** a fold, **When** the person opens it, **Then** the hidden lines appear in place and
   the reader's place does not jump.
3. **Given** several changes, **When** the person steps to the next or previous change, **Then**
   the view moves to it.
4. **Given** a Whole file view, **When** it is shown, **Then** each line shows its line number in
   the file as it now stands, and removed lines show none.

---

### User Story 4 - Code in the conversation and in pages matches (Priority: P3)

The agent answers with a fenced `ts` block. It is coloured as TypeScript, in the same palette the
files pane uses. A block with no language tag, or one the app does not know, is plain.

**Why this priority**: The person moves between a code block, the edit below it and the file it
came from. The same code looking three different ways makes them read it three times.

**Independent Test**: Ask an agent for one fenced block in each of three languages and one with
no tag. Each tagged block is coloured for its language; the untagged one is plain.

**Acceptance Scenarios**:

1. **Given** a fenced block tagged with a known language or a common alias of one (`ts`, `py`,
   `sh`, `yml`), **When** it is shown in a message or a page, **Then** it is coloured for that
   language.
2. **Given** a fenced block with no tag or an unknown tag, **When** it is shown, **Then** it is
   plain, as today.

---

### User Story 5 - The same on the phone and the iPad (Priority: P3)

The person reads the same file, the same edit and the same code block on their phone. It is
coloured and diffed the same way as on the Mac, fits the narrower screen, and does not make the
phone slow or warm.

**Why this priority**: The phone is where the person checks on agents away from the Mac (029,
033, 034). A diff that is only readable on the Mac is one they cannot act on from there.

**Independent Test**: Open the file, edit and code block from Stories 1, 2 and 4 on a phone and
an iPad. Each matches the Mac in colour and in what is marked.

**Acceptance Scenarios**:

1. **Given** a coloured file on the phone, **When** it opens, **Then** it is coloured as on the
   Mac and meets the same time limits (SC-001).
2. **Given** an edit on the phone, **When** it is shown, **Then** it shows the same removed,
   added and changed-word marks as on the Mac.

---

### Edge Cases

- **Unknown kind.** A file or block whose language the app does not recognise is plain text, as
  today. Not an error, not a guess.
- **Wrong extension, or none.** A script with no extension but a `#!/usr/bin/env python3` first
  line is recognised by that line; a `Dockerfile` or `Makefile` by its name.
- **Embedded languages.** A Markdown file's fenced blocks are coloured for their own language.
  Other nesting (script in HTML, SQL in a string) may be coloured as the outer language only.
- **Broken code.** A file the agent is half way through writing, with an unclosed string or
  bracket, is still coloured as well as can be, and a colouring mistake never hides text.
- **Very large files.** Past a size where colouring would be slow (FR-018), the file is shown
  plain, promptly, with a line saying it is shown without colour because of its size.
- **Very long lines.** A minified file with one 200 KB line is shown without colour and never
  stalls the app.
- **A diff with nothing in common.** Old and new text share no lines: all old lines removed, all
  new added, no changed-word marks, as today.
- **A huge edit.** Past 035's draw limit, the edit still waits to be asked for; word marking is
  skipped for lines too long to compare quickly.
- **Whitespace-only change.** A line whose only change is indentation or trailing space is marked
  as changed, and the changed-word mark shows where.
- **Binary or unreadable file.** Unchanged from today.
- **Accessibility.** Colour is never the only way something is conveyed: added, removed and
  changed words have marks that survive colour blindness, Increase Contrast and grey-scale.
  VoiceOver reads a diff line with whether it was added or removed.

## Requirements *(mandatory)*

### Functional Requirements

**Colour by language**

- **FR-001**: Code MUST be coloured by what each part of it is — at least keywords, strings,
  comments, numbers, type names, function names and punctuation — in the files pane, the Changes
  pane (edits and Whole file), edits in the conversation, and fenced code blocks in messages and
  pages.
- **FR-002**: Colouring MUST cover at least these kinds of file: Swift, Objective-C, C, C++,
  Python, JavaScript, TypeScript (with JSX and TSX), Go, Rust, Java, Kotlin, Ruby, shell (sh,
  bash, zsh), JSON, YAML, TOML, HTML, CSS, SQL, Markdown, Dockerfile and Makefile.
- **FR-003**: A file's kind MUST be recognised by its extension, by well-known file names, and by
  a `#!` first line; a fenced block's by its language tag and the common aliases of it.
- **FR-004**: Colours MUST come from the app's theme (Paper, Light, Dark), follow it when it
  changes, meet readable contrast against their background, and stay quiet: no colour used for
  code MAY be one the app uses to mean something went wrong.
- **FR-005**: A kind the app does not recognise MUST be shown as plain text, exactly as today.
- **FR-006**: Colouring MUST never change, hide, reorder or add text; selecting and copying MUST
  give the plain text.
- **FR-007**: Text that is still being written MUST be coloured as it arrives, with the reader's
  place kept (as 022 and 034 keep it today).

**Diffs**

- **FR-008**: An edit MUST be shown as a line diff of its old and new text: lines both share shown
  once as context, and only differing lines marked removed or added, in the order they fall.
- **FR-009**: Where a removed line and its replacement differ by part of the line, the differing
  part MUST be marked within each line, more strongly than the line's own mark.
- **FR-010**: Long unchanged runs, in an edit and in Whole file, MUST be folded to a few lines of
  context either side, with a line saying how many lines are hidden that opens them in place.
- **FR-011**: Change MUST be shown by mark (`+`/`−`), weight and at most a faint neutral tint,
  never by red and green (035 FR-013); code colour stays underneath.
- **FR-012**: Whole file MUST let the person step to the next and previous change.
- **FR-013**: Whole file MUST show each line's number in the file as it now stands; an edit MUST
  show line numbers wherever they can be known.

**One look**

- **FR-014**: Code MUST look the same wherever it appears: the same palette, type size, line
  spacing and marks in the files pane, Changes, the conversation and pages.
- **FR-015**: Existing behaviour MUST be kept: line numbers and wrapping in the files pane, the
  line an agent names being brought into view, 035's draw limit, and each view's handling of
  binary and unreadable files.

**Limits**

- **FR-016**: Colouring and diffing MUST work offline, with nothing fetched at run time, and MUST
  NOT need a web view.
- **FR-017**: The first screen of a file MUST appear no later than it does today because of this
  feature; colour MAY arrive a moment after the text, but the text MUST NOT wait for it.
- **FR-018**: Past a size (in total and per line) where colouring cannot meet SC-001, a file MUST
  be shown plain with a line saying why; the same for word marking in a very long changed line.
- **FR-019**: Scrolling a coloured file or diff MUST stay as smooth as scrolling plain text does
  today.
- **FR-020**: Adding a language MUST be a contained change: it MUST NOT need changes to the views
  that show code.
- **FR-021**: Every requirement here MUST hold on the Mac, the phone and the iPad.

### Key Entities

- **Language**: a kind of code the app can colour; recognised from a file's extension, name or
  first line, or a fenced block's tag and aliases.
- **Code span**: a stretch of text and what it is (keyword, string, comment, …); the only thing
  colouring produces. Never changes the text.
- **Diff line**: a line of an edit or of Whole file, marked context, removed or added, with its
  line number where known and its changed-word ranges.
- **Fold**: a run of unchanged lines hidden behind one line saying how many, open or closed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A 5,000-line source file in any FR-002 language opens coloured in the files pane in
  under half a second on the Mac and under one second on a current phone, measured from choosing
  it to colour being on screen.
- **SC-002**: Scrolling a coloured 5,000-line file from top to bottom drops no more frames than
  scrolling the same file plain does today.
- **SC-003**: The app, on the Mac and on the phone, grows by no more than 10 MB in download size
  with every FR-002 language included.
- **SC-004**: For a one-word change in a 40-line edit, the edit shows at most 10 lines by default
  (context, one removed, one added), against 80 today.
- **SC-005**: A 200 KB single-line file and a 20 MB file each open without the app becoming
  unresponsive, shown plain within one second.
- **SC-006**: Every FR-002 language colours a representative sample file with no text lost,
  reordered or altered, checked by comparing the shown text with the file.
- **SC-007**: In all three themes, every code colour meets a 4.5:1 contrast ratio against its
  background, and added, removed and changed-word marks remain distinguishable in grey-scale.

## Assumptions

- **Rendering stays on the device.** Colouring and diffing happen where the code is shown, from
  text the app already has. The daemon's protocol and what it sends are unchanged; the phone
  receives the same text it does today.
- **Colour, not understanding.** This is colour by syntax, not by meaning: no jump to definition,
  no hover, no errors, no knowledge of the project's other files.
- **Read only.** No editing of code is added. Pages (022) keep their own typing surface; their
  fenced code blocks are coloured, not made editable.
- **A library is expected.** No system framework on the Mac or iOS colours source code, so a
  third-party one is expected, chosen in planning against FR-016 to FR-021 and SC-001 to SC-003:
  native code over a bundled script engine, well maintained, working on macOS and iOS, and
  licensed for the app. The line and word diff can use what the language's standard library
  already provides.
- **Word marks, not moves.** A block of lines moved elsewhere is shown as removed in one place
  and added in the other, as `git diff` shows it.
- **Theme.** The paper theme's System/Light/Dark setting (merged `b59a2a6`) is the theme colours
  follow.
- **Out of scope.** Search within a file, a minimap, side-by-side diffs, code folding by
  structure (functions, blocks), image and PDF previews, and the browser pane.
- **Depends on 035.** The Changes pane, its draw limit and Whole file are 035's and are merged.
