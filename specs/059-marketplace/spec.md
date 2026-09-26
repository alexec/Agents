# Feature Specification: Search a Catalogue and Add Skills to You or a Project

**Feature Branch**: `agents/059-marketplace`

**Created**: 2026-09-26

**Status**: Draft. Look gate approved by Alex 2026-09-26, as drawn: [look/](look/README.md), frames A–E

**Input**: User description: "I'd like the user to be able to search and install skills, plugins, and MCPs." Clarified the same day: "we're searching marketplaces and allowing the user to add these to their project or user config." The feasibility note is `.agents/research/install-from-catalogues.md`. This spec covers the first slice, **skills**. MCP servers and plugins come in later slices through the same sheet (see Scope).

## Why this feature exists

054 made `~/.agents` the one place a skill goes to reach every agent, and the dotagents layout
made `<project>/.agents` the same for a project. Getting a skill *into* either place still happens
outside the app: the person finds it on a website, runs `npx skills add` in a terminal, or copies
a folder by hand. Then they check Settings ▸ Shared to see whether it arrived. A project's own
skills don't appear anywhere in the app.

This feature lets the person search a public skills catalogue from inside the app, see exactly
what a skill contains, and add it either to their own config or to a project's. What was added,
from where and at which commit is recorded, so it can later be updated or removed.

## Scope

- **In:** skills, from skills.sh; adding to the person's `~/.agents/skills` or to a project's
  `.agents/skills`; a Skills section on the project page; Update and Remove for skills the app
  added.
- **Later slices, same sheet:** MCP servers from the official MCP Registry, then plugins from
  plugin marketplaces. They need decisions this slice does not: where secrets go, and a
  project-level `mcp.json`.
- **Out:** the Remote (iOS) app; servers (remote hosts) get nothing new; publishing skills;
  catalogues that need an account.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Find a skill and add it for every agent you start (Priority: P1)

In Settings ▸ Shared ▸ Skills the person chooses **Add skill…** (frame A). A sheet opens, set to
add to them (frame B). They type "swiftui" and see matching skills, most installed first. Each
result shows its name, owner and repository, and install count. They choose one and see its
SKILL.md, every file that comes with it, and which runtimes will get it (frame C). Then they
choose **Add to ~/.agents**. The skill appears in the list. The next agent they start, on any
runtime, has it.

**Why this priority**: This is the feature at its smallest. Everything else builds on it.

**Independent Test**: On a scratch root and a scratch home, with the catalogue pointed at a
local fixture, search, open one result and add it. Check that the folder is in
`~/.agents/skills/<name>` with the files that were shown. Then start a Claude agent and a Codex
agent and ask each whether it has the skill.

**Acceptance Scenarios**:

1. **Given** the sheet is open and set to You, **When** the person types a query, **Then**
   matching skills appear within 2 seconds, most installed first, each with name, owner/repo
   and install count.
2. **Given** a result has been chosen, **When** the detail opens, **Then** it shows the owner,
   repository, the commit it will be taken at, SKILL.md as the agent reads it, and the full
   list of files. Nothing has been written to disk yet.
3. **Given** the detail is shown, **When** the person chooses Add, **Then** exactly the files
   shown, at the commit shown, are placed at `~/.agents/skills/<name>`. Its source and commit
   are recorded, and the sheet returns to the results with that row marked **added**.
4. **Given** the skill was just added, **When** the person starts an agent on any runtime that
   054 reaches, **Then** that agent has the skill, with no restart of the app.
5. **Given** the skill's files include scripts, **When** the detail opens, **Then** they are
   called out as scripts an agent may run, before Add is chosen.

---

### User Story 2 - Add a skill to a project (Priority: P1)

The project page gets a **Skills** section between Workflows and Worktrees (frame D). It lists
the skills in the project's `.agents/skills`. A line under the heading says they are committed
with the project. **Add skill…** there opens the same sheet, set to add to that project. Adding
writes the skill into the project's `.agents/skills`, where every agent working in that project
gets it. The app does not commit it.

**Why this priority**: Adding to either user or project config is the feature as asked. Leaving
out the project half would make it a different feature.

**Independent Test**: On a scratch project, open its page and add a skill from the fixture
catalogue. Check the folder is in `<project>/.agents/skills/<name>` and appears in `git status`
as untracked. Start an agent in the project and ask whether it has the skill.

**Acceptance Scenarios**:

1. **Given** a project page, **When** it is shown, **Then** it has a Skills section listing
   every skill in `<project>/.agents/skills` with its description. A skill the app added also
   shows its source.
2. **Given** a project with no `.agents/skills`, **When** its page is shown, **Then** the
   Skills section says there are none yet and still offers Add skill….
3. **Given** the sheet was opened from a project page, **When** it opens, **Then** Add to is set
   to that project, and the Add button names it ("Add to <project>").
4. **Given** a skill has been added to a project, **When** the person looks at the project's
   changes, **Then** the new folder and the change to `skills-lock.json` are there, uncommitted.
   The app has made no commit.
5. **Given** the sheet is open, **When** the person switches Add to between You and the
   project, **Then** the destination, the Add button's wording, the reach dots and the **added**
   marks all follow the choice without searching again.
6. **Given** a worktree lane of a project, **When** Add is used from that worktree's page,
   **Then** the skill goes into that worktree's `.agents/skills`, not the main checkout's.

---

### User Story 3 - Update or remove a skill the app added (Priority: P2)

A skill the app added records where it came from. When its source has moved past the recorded
commit, the list marks it **update** (frame A). Its detail offers Update, which shows what
changed before replacing it, and Remove. A skill the person made, or another tool put there,
offers neither.

**Why this priority**: Without this, an added skill can only be managed by hand. That is
acceptable for a first release but not for long.

**Independent Test**: Add a skill from the fixture, move the fixture's repository on by one
commit that changes SKILL.md, reopen Shared ▸ Skills, and check the update mark. Update it and
check the folder matches the new commit. Remove it and check the folder is gone and the record
with it.

**Acceptance Scenarios**:

1. **Given** a skill the app added, **When** its source has a newer commit that changes the
   skill's files, **Then** the row shows **update**. Nothing changes on disk until the person
   chooses Update.
2. **Given** Update is chosen, **When** it runs, **Then** the person sees which files changed
   before confirming, and afterwards the folder matches the new commit and the record names it.
3. **Given** a skill the app added, **When** Remove is chosen and confirmed, **Then** the folder
   is moved to the Trash and its record removed. Any link 054 made for it is gone before the
   next agent starts.
4. **Given** a skill the app did not add, **When** its detail is shown, **Then** it has no
   Update and no Remove, only Reveal and Edit as today.
5. **Given** a skill the app added and the person then edited, **When** Update is offered,
   **Then** the person is told their edits would be lost, and Update needs a second
   confirmation.

---

### User Story 4 - Know when it can't go in (Priority: P2)

A skill with the same name is already where Add to points, or the catalogue can't be reached
(frame E). The sheet says which, and nothing the person has is touched.

**Independent Test**: With a hand-made `~/.agents/skills/review`, try to add a catalogue skill
named `review` to You. Then stop the fixture server and search.

**Acceptance Scenarios**:

1. **Given** a hand-made or other-tool skill with the same name at the destination, **When**
   its detail opens, **Then** Add is not offered, the sheet says where the existing one is and
   offers Reveal, and it notes whether the other destination is free.
2. **Given** a skill the app itself added with the same name and source, **When** the detail
   opens, **Then** it shows as **added**, with Update if newer.
3. **Given** a skill the app itself added with the same name from a *different* source,
   **When** the detail opens, **Then** Add becomes Replace and needs confirming.
4. **Given** the catalogue or GitHub can't be reached, **When** the person searches or opens a
   result, **Then** the sheet says so in words, keeps the query and offers Try again. Nothing
   already added is affected.
5. **Given** a download fails part way, **When** it stops, **Then** nothing is left at the
   destination: no half folder and no record.

---

### Edge Cases

- **Not a skill.** The chosen folder has no SKILL.md, or its SKILL.md has no name or
  description: the detail says so and Add is not offered.
- **Name from the catalogue differs from the folder name or SKILL.md name.** The folder is named
  from SKILL.md's `name`, since that is how agents know it. Where the catalogue shows a different
  name, the detail shows both.
- **A very large skill.** More than 10 MB or 500 files: the detail says so and Add is not
  offered, since skills are meant to be small.
- **Links or odd paths in the download.** Symbolic links and anything that would land outside
  the skill's folder are not written. The detail lists what was skipped.
- **The project has no `.agents` yet.** Adding creates `.agents/skills`, and 054's project layout
  then makes Claude's link as for any project.
- **The same skill in both places.** Allowed. The project's copy is the one agents in that
  project get, as 054 already has it. The project page and Shared ▸ Skills each show that copy,
  and Shared's existing clash notice covers it.
- **`npx skills` used as well.** Skills it added appear with their source, because the app reads
  and writes the same record. Update and Remove from the app work on them too. Skills the app
  adds are seen by `npx skills update`.
- **A project on a server (remote host).** Its page has no Add skill… in this slice. The Skills
  section lists what is there, read-only.
- **The app is in a scratch root.** Downloads, the destination and the record all use the scratch
  home, never the real one, so a walk cannot change the person's own skills.

## Requirements *(mandatory)*

### Functional Requirements

**Search**

- **FR-001**: The app MUST offer one Add sheet for skills, opened from Settings ▸ Shared ▸
  Skills (destination: the person) and from a project page's Skills section (destination: that
  project).
- **FR-002**: The sheet MUST search skills.sh as the person types, pausing briefly before each
  search. It MUST list results most installed first, each with name, owner, repository and
  install count.
- **FR-003**: Rows whose owner is on the app's known-owners list MUST carry a **known** mark.
  Other rows MUST NOT be marked as a warning.
- **FR-004**: Rows already present at the current destination MUST carry an **added** mark.
- **FR-005**: The sheet MUST have an **Add to** choice between the person and the project it was
  opened from. Changing it MUST update the destination, marks, reach and Add wording without a
  new search. Opened from Settings, the project half lists the person's projects, with the
  selected project first.

**Look before adding**

- **FR-006**: Choosing a result MUST fetch that skill at its repository's current commit, and
  show:
  - owner and repository, with links;
  - the commit;
  - the install count;
  - the destination path;
  - SKILL.md rendered;
  - every file;
  - the runtimes that will get it at that destination.

  Nothing is written to the destination at this point.
- **FR-007**: Files that an agent could run MUST be called out before Add. These are anything in
  `scripts/`, anything executable, and files with a shebang.
- **FR-008**: Add MUST write exactly the files shown, from the commit shown. A change upstream
  between showing and adding MUST NOT be picked up.

**Add**

- **FR-009**: Add MUST write the skill to the destination in full or not at all. It prepares the
  skill beside the destination and moves it into place only when complete.
- **FR-010**: Add MUST record, for each skill it adds:
  - the source repository;
  - the path in it;
  - the commit;
  - a fingerprint of the folder;
  - when it was added.

  For `~/.agents` this is the record `npx skills` keeps (`~/.agents/.skill-lock.json`), so that
  each tool sees the other's skills. For a project, it is the record `npx skills` keeps for a
  project (`skills-lock.json` at the project root). That file is committed with the project, so
  anyone who clones it can see where each skill came from, and `npx skills experimental_install`
  can restore them.
- **FR-011**: After Add to the person, the next agent started on any runtime MUST have the skill
  without restarting the app, through 054's existing layout.
- **FR-012**: After Add to a project, every agent then started in that project MUST have the
  skill, through the project's existing layout. The app MUST NOT commit, stage or push.
- **FR-013**: Add MUST NOT write over any skill it did not add itself (FR-010 record absent or
  pointing elsewhere). It MAY replace one it added, after confirmation.
- **FR-014**: Add MUST refuse a folder with no valid SKILL.md, one over 10 MB or 500 files, and
  anything that would land outside the skill's folder. Links MUST NOT be written.

**The project page**

- **FR-015**: A project page MUST have a Skills section between Workflows and Worktrees. It lists
  the skills in `<project>/.agents/skills` with their descriptions and, for those the app added,
  their source. The section also has Reveal in Finder and Add skill….
- **FR-016**: The section MUST say, under its heading, that these skills are committed with the
  project and reach everyone who clones it.
- **FR-017**: A worktree's page MUST read and write that worktree's `.agents/skills`.

**Update and remove**

- **FR-018**: For skills the app added, the app MUST check whether the source has moved past the
  recorded commit and changed the skill's files. The check runs when Shared ▸ Skills or a project
  page is opened, at most once an hour per source. Such skills are marked **update**.
- **FR-019**: Update MUST show which files change before confirming, and MUST warn and ask again
  when the local folder no longer matches its recorded fingerprint (the person has edited it).
- **FR-020**: Remove MUST move the folder to the Trash, drop its record, and leave no link from
  054 in place by the next agent start. It is offered only for skills the app added.
- **FR-021**: Skills the app did not add MUST keep exactly today's actions (Reveal, Edit).

**Failures and safety**

- **FR-022**: When the catalogue or the source can't be reached, the sheet MUST say which, keep
  the query and offer Try again.
- **FR-023**: All network access for this feature MUST go to the catalogue and to the source
  host only (skills.sh, GitHub). No personal data or project content is sent. The query and the
  repository being fetched are the only things that leave the Mac.
- **FR-024**: In a scratch root, every path this feature writes MUST resolve under the scratch
  home. The catalogue and source hosts MUST be replaceable for tests.

### Key Entities

- **Catalogue result**: one skill a catalogue lists: name, owner, repository, path in the
  repository (when known), install count, whether the owner is known.
- **Skill preview**: a result fetched at one commit: files, SKILL.md, runnable files, total size,
  destination, reach.
- **Added-skill record**: what the app (or `npx skills`) added: the destination (person or
  project), name, source repository and path, commit, folder fingerprint, when added and updated.
- **Destination**: the person (`~/.agents/skills`) or one project or worktree
  (`<folder>/.agents/skills`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person can go from opening the sheet to a skill being available to their next
  agent in under one minute, with no terminal.
- **SC-002**: Search results appear within 2 seconds of the person stopping typing, on a normal
  connection.
- **SC-003**: In every add, update and remove in the test suite, including interrupted ones, the
  destination is left either exactly as before or exactly as shown. Never in between.
- **SC-004**: No skill the app did not add is ever changed or removed by this feature, across the
  whole test suite.
- **SC-005**: A skill added in the app is reported by `npx skills list` (global or project, as
  added), and one added by `npx skills add` shows its source in the app.
- **SC-006**: Every agent runtime 054 reaches has a skill added to You at its next start, and
  every runtime that reads project skills has one added to a project.

## Docs *(mandatory)*

- `docs/how-to/add-a-skill-from-a-catalogue.md`: add. How to search, look before adding, add
  to yourself or to a project, update and remove, and what "known" means.
- `docs/how-to/share-skills-across-agents.md`: change. Point to the new how-to as the way in,
  alongside by hand and `npx skills`.
- `docs/reference/settings.md`: change. Shared ▸ Skills gains Add skill… and, for added skills,
  Update and Remove.
- `docs/explanation/projects-hosts-worktrees.md`: change. The project page's new Skills section,
  and that a worktree has its own `.agents/skills`.
- `docs/explanation/scoped-tools.md`: change, one short section on trust. Skills.sh does not
  review what it lists, so the app shows everything before adding and pins the commit.

## Assumptions

- skills.sh's public search (`/api/search?q=`) stays open without a key. The feasibility check
  on 2026-09-26 returned up to 100 results with name, source repository and installs, but no
  description. If it closes, the sheet says the catalogue can't be reached (FR-022). A second
  catalogue is a later slice.
- Skills live on GitHub. Other hosts are out of this slice. Fetching uses GitHub's archive
  download rather than its rate-limited API, and needs no git on the Mac.
- The known-owners list ships with the app and is short. It marks, it does not gate: any skill
  can be added.
- The skill format and precedence (project over person) are what 054 and the dotagents layout
  already settled. This feature changes neither.
- This slice never offers MCP servers or plugins. The sheet and records are designed so those
  slices can reuse them.
- The layout was approved as drawn (look gate, 2026-09-26): Add in Shared's bar and the project
  section's heading, the known-owner mark kept, and the project section showing skills only.
