# Feature Specification: Visual Consistency — One Attention Colour, One Chat Scale, One Measure

**Feature Branch**: `018-visual-consistency`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "Review the visual layout. Are we using the same colors for 'needs attention'. Is the font size of the chat consistent, as it seems a bit small." — extended in the same conversation with: "The chat has padding, but when the window is narrow it ends up being mostly padding."

## Overview

Two things drifted while features 009–017 were built one at a time.

**Colour.** The app has a stated rule — colour is rare, and it means something. Three separate places say in a comment that they are "the app's one use of colour", and all three picked a different colour for the same idea. An agent that needs a person is orange in the agent list and in chat, red in a workflow row and on a project heading, and the system accent colour on the phone. A person moving between those surfaces is being taught three different things.

**Size.** Chat sets no size of its own, so the prose an agent writes lands at the platform default while nearly everything around it — a thought, a tool call, a picture that could not be drawn — sits a step or two below. The page reads smaller than the text in it actually is, because most of what is on the page is the smaller part.

**Measure.** The chat insets itself by a fixed gutter on each side, and a gutter that
does not know how wide the pane is will eventually be wider than the thing it surrounds.
The pane does not get the window — it shares the detail column with the right sidebar —
so at the default window size, with the sidebar open, most of the chat's width is margin.
The gutter was set for one window and is applied to all of them.

None of the three is a new capability. This is the layout being made to agree with
itself, and with the size of the space it is given.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One colour means one thing (Priority: P1)

A person has six agents running across three projects. Two of them have stopped and want an answer. They glance at the agent list, see orange, and go to those two. They open the project page and the workflow that stalled is orange too. They pick up their phone, and the agent waiting there is orange as well. Nothing they see in any of those places is orange unless a person is needed.

Separately, one project's folder has been moved on disk. That is red, and it stays red, because it is not waiting for a decision — it is broken.

**Why this priority**: It is the whole point. Colour that means three things means nothing, and the list of agents is the screen this app exists to show.

**Independent Test**: Put the app into a state with one waiting agent, one stalled workflow, one failed project folder, and one healthy agent. Every surface that draws them — Mac agent list, Mac project page, Mac workflow row, Mac chat, phone project list, phone agent card, phone chat — can be checked by eye and by snapshot: attention is one hue, failure is a different one, everything else is grey.

**Acceptance Scenarios**:

1. **Given** an agent whose outcome needs a person, **When** it is drawn in the Mac agent list, the Mac chat transcript, the phone agent card and the phone chat, **Then** all four use the same attention colour.
2. **Given** a workflow whose last run needs a person, **When** its row is drawn, **Then** it uses the attention colour, not the failure colour.
3. **Given** a project whose folder no longer exists, **When** its heading is drawn, **Then** it uses the failure colour, and that colour is not the attention colour.
4. **Given** an agent that finished cleanly and one that is simply running, **When** either is drawn anywhere, **Then** neither carries the attention colour.
5. **Given** any surface in the app, **When** a person looks for what needs them, **Then** the attention colour appears nowhere that does not need them.

---

### User Story 2 - Chat reads at one size (Priority: P1)

A person reads a long transcript. The agent's prose, its thinking, the tool it ran and the note about a picture it could not draw all sit on one scale. Nothing on the page is two steps smaller than the thing above it for no reason, and the transcript no longer reads as cramped.

**Why this priority**: The user raised it directly, and chat is where the time is spent. It is also the change that makes the app feel finished rather than assembled.

**Independent Test**: Open a transcript containing every entry kind — prose, thought, tool call, tool detail, plan, diff, an app-asked question, an attachment, an undrawable block. Measure the rendered size of each. Two steps is the maximum spread, and the same entry kind is the same size on Mac and phone.

**Acceptance Scenarios**:

1. **Given** a transcript with an agent message and an agent thought adjacent, **When** both are drawn, **Then** they differ by at most one step on the type scale.
2. **Given** the same transcript opened on Mac and on the phone, **When** each entry kind is compared across the two, **Then** each kind sits at the same relative step of its platform's scale.
3. **Given** a message containing a picture the app cannot draw, an audio block, a resource link and an unknown block, **When** it is drawn on Mac and on the phone, **Then** the corresponding placeholders are the same size as each other on both.
4. **Given** a person has increased text size in system accessibility settings, **When** chat is drawn, **Then** every part of the transcript scales with it and none is pinned to a fixed point size.
5. **Given** a long transcript, **When** a person reads it at default settings, **Then** the body prose is no smaller than the platform's standard reading size.

---

### User Story 3 - The chat fits the space it is given (Priority: P1)

A person drags the window narrow, or opens the right-hand sidebar beside the chat, and
the conversation goes on being readable. The margin gives way before the text does.
Widen it again and the line length stops growing once it reaches a comfortable measure,
rather than running the full width of a large display.

**Why this priority**: At the default window with the sidebar open, more of the chat's
width is currently margin than text. It is the most visible of the three problems and
the one a person hits without doing anything unusual.

**Independent Test**: Open a conversation and drag the window from its narrowest to its
widest, with the sidebar both open and shut. The text column never falls below a
readable width, never collapses, and never exceeds the measure ceiling.

**Acceptance Scenarios**:

1. **Given** a chat pane narrower than the text measure plus its margins, **When** the
   transcript is drawn, **Then** the margin shrinks to its floor and the text takes the
   rest, rather than the margin holding its size and squeezing the text.
2. **Given** the default window with the right sidebar open, **When** the transcript is
   drawn, **Then** the text occupies more of the pane than the margins do.
3. **Given** a chat pane wider than the measure ceiling, **When** the transcript is
   drawn, **Then** the text column stops at the ceiling and the surplus is split evenly
   either side.
4. **Given** any pane width, **When** the transcript and the prompt bar are drawn,
   **Then** their left and right edges line up exactly.
5. **Given** the window is dragged continuously from narrow to wide, **When** the
   transcript is watched, **Then** the column grows and settles without jumping.

---

### User Story 4 - The rules are written down where the next feature will find them (Priority: P2)

The next person to add a surface does not have to guess, and does not have to grep for the comment that says "the app's one use of colour". There is one place that names the attention colour and the failure colour, one place that names each chat text step, and a check that fails if a new surface hard-codes its own.

**Why this priority**: Without it this fix decays. Three surfaces already drifted apart this way; a fourth will. But it delivers nothing a person can see, so it ranks below the two that do.

**Independent Test**: Add a new surface that hard-codes a colour for a waiting agent and confirm the check catches it.

**Acceptance Scenarios**:

1. **Given** the codebase after this feature, **When** somebody searches for where the attention colour is decided, **Then** there is exactly one answer.
2. **Given** a change that introduces a literal colour for an attention or failure state at a call site, **When** the test suite runs, **Then** it fails and says where.

---

### Edge Cases

- **An agent that is both waiting and failed.** A refusal that needs a person is still a thing a person must act on. It takes the attention colour, because that is the action; the failure colour is for states nobody can act on from that screen.
- **Colour-blind readers.** The attention colour must never be the only signal. Every surface that tints for attention already carries an icon and words; this feature must not remove either, and must not introduce a surface where colour is the sole carrier.
- **An accent colour that collides.** A person whose system accent is set to the attention hue must still be able to tell a waiting agent from an ordinary control. Attention must not be drawn as the system accent colour.
- **Dark mode and reduced transparency.** Both colours must stay legible against every background the app uses, on both platforms.
- **A count of zero.** A surface that shows "3 need attention" must not tint itself when the count is nought.
- **Very large accessibility text.** Rows that currently fit one line must degrade by wrapping or truncating with a tooltip, not by clipping.
- **Archived agents and workflows.** An archived thing needs nobody, whatever its last outcome said. It is never tinted.
- **A pane narrower than the margin floor.** The text keeps the space; the margin gives
  way to its floor and no further. The transcript must never be reduced to nothing.
- **The right sidebar opening while a conversation is on screen.** The chat column
  re-measures to the space left over, and the transcript stays where the reader was.
- **A very wide display.** The column stops at the measure ceiling rather than running
  the full width, and the surplus is margin, not line length.
- **Large accessibility text against the measure ceiling.** The ceiling is a ceiling on
  the column, not on how much text fits in it; bigger text means fewer words per line,
  not a clipped column.

## Requirements *(mandatory)*

### Functional Requirements

#### Colour

- **FR-001**: The app MUST define exactly one attention colour, used wherever a person is needed, and exactly one failure colour, used wherever something is broken and cannot be acted on from that screen.
- **FR-002**: The attention colour MUST be orange, and the failure colour MUST be red. A third colour, green, MUST be reserved for a completion the app can vouch for — an agent that reported `done` itself — and MUST be used for nothing else.
- **FR-003**: Every surface that currently tints for "needs a person" — the Mac agent list, the Mac chat transcript, the Mac workflow row, the Mac project page, the Mac project list, the phone project list, the phone agent card and the phone chat — MUST use the attention colour and no other.
- **FR-004**: Surfaces that tint for a broken or exhausted condition — a missing project folder, a spend limit reached, a runtime that needs signing in, a tool call that failed — MUST use the failure colour.
- **FR-005**: The attention colour MUST NOT be the system accent colour, so that it remains distinguishable from ordinary interactive controls.
- **FR-006**: No surface MAY tint anything for a state outside the three the app has colours for. Running, stopped, archived, and an ending nobody vouched for stay untinted.
- **FR-006a**: Orange MUST mean "a person is needed" and nothing else. The three places that currently spend it on something else — an artifact that is no longer on disk, a warning shown while a cost limit is being set, and an agent that has reached its cost limit — MUST move to the failure colour.
- **FR-006b**: A colour used for an ordinary interactive control — a link, a button that opens something — is not a state tint and is out of scope. This feature MUST NOT change those.
- **FR-007**: Colour MUST NOT be the only indicator of an attention or failure state; each such state MUST also carry an icon, text, or both.
- **FR-008**: Both colours MUST remain legible in light and dark appearance on both platforms.

#### Chat text size

- **FR-009**: The chat transcript MUST define its text steps in one place, and every entry kind MUST draw from that definition rather than choosing a size at its call site.
- **FR-010**: Agent prose and person prose MUST render at the platform's standard reading size.
- **FR-011**: Supporting content in the transcript — thoughts, tool call titles, the app's own question, resource links, and placeholders for content the app cannot draw — MUST render one step below prose, not two or more.
- **FR-012**: Fine print in the transcript — timestamps, block labels, language tags, per-entry metadata — MUST render at most two steps below prose.
- **FR-013**: The Mac and the phone MUST place each entry kind at the same relative step of their respective platform scales.
- **FR-014**: Placeholder blocks that currently differ between the two apps (undrawable picture, audio, resource link, unknown block) MUST be brought to the same step as each other and as their cross-platform counterpart.
- **FR-015**: All transcript text MUST scale with the reader's system text-size setting; no transcript text may be pinned to a fixed point size. Decorative glyphs that are not text are exempt.
- **FR-016**: Monospaced content — code blocks, diffs, command names — MAY sit one step below its surrounding prose to compensate for monospace running visually larger, and MUST be consistent about doing so.

#### Chat measure

- **FR-017**: The chat MUST cap its text column at a readable measure rather than inset it by a fixed margin, so that the margin is whatever space is left over.
- **FR-018**: When the chat pane is narrower than the measure, the margin MUST shrink to a small floor and the text MUST take the remaining width.
- **FR-019**: The margin MUST never consume more of the chat pane than the text does, at any pane width the app can produce.
- **FR-020**: When the chat pane is wider than the measure, the surplus MUST be divided evenly either side, centring the column.
- **FR-021**: The transcript and the prompt bar MUST draw their horizontal edges from one shared definition, so the two cannot be changed independently and drift apart.
- **FR-022**: The measure MUST be expressed as a ceiling on column width, not as a limit on content, so that larger accessibility text reflows within the column rather than being clipped by it.
- **FR-023**: Changing the pane width — by resizing the window, collapsing the project list, or opening and closing the right sidebar — MUST NOT move the reader's position in the transcript.

#### Keeping it

- **FR-024**: A check MUST fail when a call site introduces a literal colour for an attention or failure state instead of the shared definition.
- **FR-025**: A check MUST fail when a transcript entry introduces a text size not drawn from the shared definition.
- **FR-026**: A check MUST fail when a chat surface introduces a fixed horizontal margin instead of the shared measure.
- **FR-027**: The existing wording and icons for each state MUST be unchanged by this feature; only colour, size and measure move.

### Key Entities

- **Attention state**: The single idea that a person is needed. Derived from an agent waiting on a user, an agent whose reported outcome needs a person, or a workflow whose last run needs a person. Already computed today in more than one place; this feature makes the places agree on what it looks like, not on what it means.
- **Failure state**: Something broken that the screen cannot act on — a folder that has gone, a limit reached, a sign-in required, a call that failed.
- **Chat measure**: The one definition of how wide the chat's column of text may get
  and how little margin it may keep, used by the transcript and the prompt bar alike.
- **Transcript text step**: A named position on the type scale (prose, supporting, fine print, monospace) that every chat entry draws from, defined once per platform.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Across every surface in both apps, the number of distinct colours used to signal "a person is needed" is exactly one. It is three today. Orange appears nowhere that does not need a person; it appears in three such places today.
- **SC-002**: A person shown a screenshot of any surface can say whether it needs them, with no other context, and is correct every time.
- **SC-003**: The spread between the largest and smallest text in a chat transcript is at most two steps of the type scale, down from four today.
- **SC-004**: The same transcript, compared entry-kind by entry-kind between Mac and phone, shows no kind sitting at a different relative step.
- **SC-005**: A person who said the chat looked small agrees it no longer does.
- **SC-006**: Every attention and failure state in the app is identifiable without colour — by icon or words alone.
- **SC-007**: Introducing a hard-coded state colour, a stray chat text size, or a fixed chat margin causes a test to fail, named and located.
- **SC-008**: No screen loses content or gains clipping at the largest system text size.
- **SC-009**: At every pane width the app can produce, the chat's text is wider than its combined margins. At the default window with the right sidebar open it is currently narrower than them.
- **SC-010**: The transcript's and the prompt bar's horizontal edges align at every pane width, and are set in one place rather than two.
- **SC-011**: The chat text column never exceeds the measure ceiling on a large display, and never collapses on a narrow one.

## Assumptions

- The existing semantics are right and only the presentation is wrong. Which agent needs attention is already decided correctly and consistently; this feature does not revisit that logic.
- Red keeps its present meaning — genuinely broken, not merely waiting — so the missing-folder, spend-limit, sign-in and failed-call surfaces keep it, and the three surfaces currently using orange for that kind of news join them.
- Green survives as a third colour. Feature 014 gave it deliberately to an agent that reported `done` itself, on the grounds that a self-reported completion is the one ending the app can vouch for. Narrowing the palette to two would have thrown that away, so the rule is three colours with one meaning each rather than two.
- An agent at its cost limit is treated as blocked rather than as needing a person. It is waiting on a ceiling being raised, which is a thing that is broken about its situation rather than a question it has asked.
- The user story about chat size is satisfied by raising the surrounding chrome to meet the prose, not by enlarging the prose itself. Transcript density is therefore roughly preserved.
- "Step" means a position on the platform's semantic type scale, not a point size, so the platform keeps control of the actual numbers and accessibility scaling keeps working.
- The phone and Mac render the same transcript data through separate view code today, and that stays true — this feature makes the two agree by convention and by test, not by merging them into shared view code.
- The logo and other brand artwork in `design/` are out of scope; this is about state colour only.
- The chat column centres once the pane exceeds the measure, matching what the phone and
  iPad already do, rather than staying pinned to the left edge. This is a visible change
  on a wide window and was chosen deliberately for one rule across both apps.
- A readable measure is treated as a property of text, not of this app, so the ceiling is
  close to what the Mac's current gutter already yields at the default window size. The
  look at that size barely changes; only the narrow and very wide cases do.
- No new user-facing setting is introduced. Chat text size and column width follow the
  system and the window, not an app preference.
