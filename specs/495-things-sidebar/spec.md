# Feature Specification: Things-style sidebar

**Feature Branch**: `agents/sidebar-things`

**Created**: 2026-10-08

**Status**: Draft

**Input**: User description: "#495 Things-style sidebar. Alex chose direction B: smart rows at the top across every project (Needs You, Working, maybe Unread); projects below as flat rows that fold open straight onto their sessions, newest first, status as a mark on the row instead of per-status fold groups (max two levels); Activity pages (Events, Resources, Runtimes, Spending) leave the sidebar top for the toolbar/menu/footer; workflows and archived sessions stay reachable without a third level. Applies to Mac, Remote and web. Layout first, settled by running it, before depth."

## Background

The sidebar today (#145) is one list: an **Activity** section (Events, Resources,
Runtimes, Spending), then **Projects**. Each project folds open on a New session row,
its pinned pages, then sub-folds — Pinned, Needs you, Working, Done, Archived sessions,
Workflows, Archived workflows — and only under those, the sessions. That is three levels,
and every project repeats the same five or six headings.

Common Mac apps that do the same job keep to two levels and put what needs the person at
the top: Things 3 and Reminders (Inbox / Today / Upcoming, then Areas and Projects),
Mail (Favorites and smart mailboxes, then accounts), and the agent apps Conductor and the
Codex / Claude desktop apps (projects, each with its sessions newest first, status as a
mark on the row). Alex chose the Things-style direction.

## Target layout (to be settled by running it)

```
┌ Sidebar ─────────────────────────────┐
│ 🔍 Search sessions and workflows      │
│                                       │
│ ● Needs You                       2   │  ← smart rows: across every project
│ ◐ Working                         3   │
│ ○ Unread                          5   │
│                                       │
│ PROJECTS                              │
│ ▾ 💬 Chat                         📌  │
│     + New Session                     │
│     ● Fix the reconnect hang     2m   │  ← needs you mark
│     ◐ Sidebar spec               now  │  ← working mark
│     • Release notes              1h   │  ← unread dot, bold
│       Tidy the docs              3d   │  ← done, plain
│     ⚙︎ Review and fix  (workflow)      │  ← pinned workflow, inline
│     Workflows                     4 › │  ← opens a page, not a fold
│     Archived                     23 › │  ← opens a page, not a fold
│ ▸ Agents                       ● 1    │  ← folded: needs-you count stays
│ ▸ devbox:api                          │
│                                       │
│ Archived projects                 ▸   │
├───────────────────────────────────────┤
│ ⚡ Kept awake · 1 host not answering   │  ← foot status, as today
└───────────────────────────────────────┘
Toolbar / Window menu: Events · Resources · Runtimes · Spending
```

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See what needs me without opening anything (Priority: P1)

Alex opens the window and, without unfolding a single project, sees how many sessions
need an answer and how many are working, across every project and host, and can open any
of them in one click.

**Why this priority**: The main reason the top of the sidebar exists. Today "Needs you"
is buried one fold down in each project, so with several projects folded it is easy to
miss that an agent is waiting.

**Independent Test**: With sessions needing answers in two different projects, all
projects folded, the top of the sidebar shows Needs You with a count of 2; opening it
lists both; clicking one opens its chat.

**Acceptance Scenarios**:

1. **Given** sessions in three projects, one needing an answer and two working, **When**
   the window opens with every project folded, **Then** the smart rows read Needs You 1
   and Working 2.
2. **Given** Needs You is open, **When** Alex clicks a session under it, **Then** that
   session's chat opens on the right and the row is selected as it would be under its
   project.
3. **Given** a session is answered, **When** it stops needing a person, **Then** it
   leaves Needs You (and the count drops) without Alex doing anything.
4. **Given** nothing needs Alex, **When** the window is open, **Then** Needs You still
   shows, with no count and in the quiet colour, so the layout does not jump.

---

### User Story 2 - A project's sessions as one flat list (Priority: P1)

Alex unfolds a project and sees its sessions straight away, newest activity first, each
saying its state with a mark (needs you, working, unread, done) — no Pinned / Needs you /
Working / Done headings to unfold first.

**Why this priority**: Removes the third level, which is the main difference from the Mac
apps Alex compared it to. Together with Story 1 it is the redesign; the rest follows.

**Independent Test**: Unfold a project with sessions in every state; every live session
is one level under the project, ordered by most recent activity, each with the right mark.

**Acceptance Scenarios**:

1. **Given** a project with sessions needing an answer, working, unread and done,
   **When** it is unfolded, **Then** they show in one list under the project with no
   group headings, most recent activity first.
2. **Given** a pinned session, **When** the project is unfolded, **Then** it shows
   first, in its pinned order, with a pin mark, ahead of the newest-first list.
3. **Given** a folded project with a session that needs an answer, **When** Alex looks
   at the project row, **Then** it shows the needs-you count in the attention colour.
4. **Given** a session's state changes, **When** it does, **Then** its mark changes in
   place; it moves only when its order by activity changes.

---

### User Story 3 - Workflows and archive without a third level (Priority: P2)

Alex can still reach a project's workflows and its archived sessions and workflows, but
as one row each that opens a page on the right rather than another fold in the sidebar.

**Why this priority**: Needed so nothing is lost, but used far less than live sessions.

**Independent Test**: In a project with workflows and archived sessions, a Workflows row
and an Archived row sit at the foot of its list; clicking each opens a page listing them,
from which any one opens.

**Acceptance Scenarios**:

1. **Given** a project with workflows, **When** it is unfolded, **Then** a Workflows row
   with a count sits after its sessions; clicking it opens the project's workflows page.
2. **Given** a pinned workflow, **When** the project is unfolded, **Then** it shows inline
   with the pinned sessions, as today.
3. **Given** a project with archived sessions or workflows, **When** it is unfolded,
   **Then** an Archived row with a count sits last; clicking it opens a page of them with
   Bring Back.
4. **Given** a project with no workflows or nothing archived, **Then** those rows are absent.

---

### User Story 4 - Activity pages out of the sidebar's top (Priority: P2)

Events, Resources, Runtimes and Spending are no longer sidebar rows. They are reached from
the window's toolbar and the Window menu (with their shortcuts), and what they say at a
glance that matters — Spending running low, a runtime failing — still reaches the person.

**Why this priority**: Frees the top for the smart rows. Lower than Stories 1–2 because
the pages themselves do not change.

**Independent Test**: With the redesign, each of the four pages opens from the toolbar
and from the Window menu; when Spending is low the toolbar button shows it.

**Acceptance Scenarios**:

1. **Given** the window, **When** Alex chooses Window ▸ Spending (or its toolbar button),
   **Then** the Spending page opens on the right as it does today from the sidebar.
2. **Given** spending left is under its warning line, **When** the window is open,
   **Then** the Spending toolbar button carries the warning mark it shows today in its row.
3. **Given** the Mac is kept awake or a host is not answering, **Then** the sidebar's foot
   still says so, as today.

---

### User Story 5 - The same sidebar on the Remote and the web page (Priority: P3)

The Remote (iPhone and iPad) and the web page draw the same smart rows and flat project
lists, adapted to touch and width.

**Why this priority**: Parity rule; follows once the Mac layout is settled by running it.

**Independent Test**: The parity table's sidebar rows read **same** on all three clients.

**Acceptance Scenarios**:

1. **Given** the Remote on iPad, **When** opened, **Then** the sidebar shows the smart rows
   and flat project lists as on the Mac.
2. **Given** the web page at phone width, **When** opened, **Then** the smart rows head the
   one-column list.

### Edge Cases

- A session that needs an answer **and** is pinned: shows in Needs You and at the top of
  its project, both with the needs-you mark.
- A project with hundreds of done sessions: the flat list shows the live and recent ones
  and a "Show N more" row, as the folds bound it today (#165, #356), never all at once.
- Search: the smart rows and project lists narrow to matches; projects with matches unfold
  while searching, as today; archived matches show under each project's Archived row as a
  count that opens the archive page filtered by the search.
- A server that is not answering: its sessions keep their last-known marks and stay in the
  smart rows, greyed, as project rows grey today.
- Selection: a session shown both under a smart row and under its project is one item; the
  highlight shows wherever it is in view and ⌘-click/bulk Archive still work across both.
- Unfolding Needs You and the project holding the same session: arrow keys walk the list
  in order, visiting it twice, as Mail does with a message in a smart mailbox.
- Drag files onto a session row inside a smart row: goes to that session's project's drop
  box, as under its project (#231).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The sidebar MUST start with smart rows that gather sessions across every
  project and host: **Needs You** (waiting on a person), **Working** (a turn running) and
  **Unread** (finished and not yet read), each with a live count.
- **FR-002**: Each smart row MUST fold open on its sessions, one level under it, each
  row naming its project; a click opens the session's chat.
- **FR-003**: Smart rows MUST always be present (count hidden when zero) so the layout
  does not move as states change.
- **FR-004**: Each project MUST fold open directly on its sessions: pinned first (in
  their order), then the rest by most recent activity, with no per-state group headings.
- **FR-005**: Each session row MUST show its state as a mark — needs you, working,
  unread, done — plus the time of last activity; unread stays a dot and bold title (#70).
- **FR-006**: A folded project row MUST show its needs-you count in the attention
  colour, and its unread count, so folding never hides that a person is waiting.
- **FR-007**: A project's workflows MUST be one **Workflows** row with a count after its
  sessions, opening the project's workflows as a page in the detail; pinned workflows
  stay inline with pinned sessions (#432).
- **FR-008**: A project's archived sessions and workflows MUST be one **Archived** row with
  a count, last in the project, opening a page of them with Bring Back.
- **FR-009**: New Session and the project's pinned pages (#159) MUST stay at the top of
  the unfolded project, as today.
- **FR-010**: Events, Resources, Runtimes and Spending MUST leave the sidebar and be
  reached from the toolbar and the Window menu, keeping any keyboard shortcuts; the
  warning marks their rows show today MUST show on their toolbar buttons.
- **FR-011**: Nothing deeper than two levels: a sidebar row is a smart row, a project, or
  a row directly under one of those.
- **FR-012**: Bounded as today: a fold draws nothing while folded (#356), a project
  shows a capped page of done sessions with "Show N more" (#165), and the smart rows
  hold only live sessions.
- **FR-013**: Search, selection, multi-select and bulk Archive, swipe actions, context
  menus, drop-box drops, project pinning (#486) and the sidebar's foot MUST keep working.
- **FR-014**: The Remote and the web page MUST draw the same structure (Story 5), recorded
  in `specs/071-web-remote/walks/parity.md`.
- **FR-015**: Layout first: the Mac sidebar's shape MUST be walked on a scratch app and
  confirmed by Alex before the Remote and web follow and before the depth (search
  details, archive page polish, keyboard walk) is built.

### Key Entities

- **Smart row**: a named, live gathering of sessions across all projects by state
  (Needs You, Working, Unread) with a count.
- **Project row**: a project (with its host in the name for servers), pin, folded counts.
- **Session row**: one session with a state mark, title, last-activity time, pin mark.
- **Project page rows**: Workflows and Archived, each opening a page in the detail.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With every project folded, the number of sessions needing an answer is
  visible at the top of the sidebar with zero clicks (today: one unfold per project).
- **SC-002**: Any live session is at most two clicks from the window's opening state
  (unfold a project or smart row, click the session); today it can be three.
- **SC-003**: No sidebar row is more than two levels deep (today: three).
- **SC-004**: An unfolded project with sessions in every state shows no group headings;
  the first session row sits directly under New Session.
- **SC-005**: Every page reachable from the sidebar today (the four Activity pages,
  workflows, archived sessions and workflows) is still reachable, in at most two clicks.
- **SC-006**: Alex, walking the scratch app, confirms the layout feels like a common Mac
  app before Remote and web work starts.

## Docs *(mandatory)*

- `docs/explanation/` sidebar page (or the window explanation) — change: smart rows,
  flat project lists, where Activity pages went.
- `docs/how-to/` pages that say "Activity in the sidebar" or "Needs you under a project"
  — change: to the toolbar / Window menu and the smart rows.
- `specs/071-web-remote/walks/parity.md` — change: the sidebar rows.

## Assumptions

- Smart rows are Needs You, Working and Unread; Unread is included because unread is
  already a first-class mark (#70) and Mail/Things both surface it at the top. Easy to
  drop after the walk.
- Smart rows fold open in the sidebar (like a project) rather than opening a list page
  in the detail, so the detail stays the chat and the one-list selection is kept.
- "Done" sessions stay in their project's flat list (plain, no mark); there is no Done
  smart row.
- Activity pages go to the toolbar and Window menu; the sidebar foot keeps its status
  lines only.
- Workflow pages and the archive page reuse today's pages in the detail; only how they
  are reached changes.
- #145's reasons for one column (Spending, busy projects and host status in sight) hold:
  this stays one column.
