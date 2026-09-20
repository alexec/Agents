# Feature Specification: Workflow Settings

**Feature Branch**: `017-workflow-settings`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "It seems to me that workflows need to have some setting set on them. Permission mode being the most important. Determine how we can add this to the tool and allow the user to modify it. I always want the user to be able to click on the workflow and view the workflow."

## Clarifications

### Session 2026-09-19

- Q: Which settings should a workflow be able to carry in this version? → A: Permission mode, the runtime, and the model — the three things the new-agent form asks before you type a prompt. Everything else a start can take (extra arguments, additional directories, MCP servers) is deferred.
- Q: When someone changes a workflow's permission mode in the app, where does that change live? → A: Written into the file. One source of truth, reviewable in a pull request, travelling with the repository like the rest of the workflow. This amends FR-032 of 008, which forbade the project page editing a workflow at all.
- Q: Clicking a workflow row should open what? → A: A detail view in the app — name, trigger in plain words, settings, the prompt body — with the settings changeable there and the body read-only.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A workflow says how much it is allowed to do (Priority: P1)

Someone has a workflow that runs at nine every weekday and checks whether the build is
green. It is a reading job, and it should not be able to change a file. Today it can:
every workflow starts on whatever runtime happens to be first in the list, with whatever
that runtime does by default, and nobody has ever been asked. They add one line to the
file saying the workflow runs in plan mode. At nine the next morning the agent starts in
plan mode, and the project page says so on the row before it ever fires.

Another workflow in the same project is the opposite — it takes the failures from
overnight and fixes them — and it says so in its own file, in the same line, with the
permission that job actually needs.

**Why this priority**: This is the unattended half of the app, and it is the half where
nobody is watching. An agent a person starts is an agent they are sitting in front of,
and the permission prompt reaches them. A workflow's agent starts at nine in the morning
whether or not anybody is at the machine, so the permission decision has to have been
made in advance and written down. Without this there is no way to make it, and no way to
see what was assumed.

**Independent Test**: Write a workflow naming a permission mode, tap Run now, and confirm
the agent it starts is in that mode and not the runtime's default.

**Acceptance Scenarios**:

1. **Given** a workflow whose file names a permission mode, **When** it fires and starts a
   fresh agent, **Then** that agent begins in the named mode.
2. **Given** a workflow whose file names a runtime, **When** it fires, **Then** the agent
   runs on that runtime rather than on whichever one the app would have picked.
3. **Given** a workflow whose file names a model, **When** it fires, **Then** the agent
   runs on that model.
4. **Given** a workflow that names none of the three, **When** it fires, **Then** it
   behaves exactly as it does today, and no existing workflow file changes meaning.
5. **Given** a workflow naming a permission mode its runtime does not offer, **When** it
   fires, **Then** no agent is started, and the refusal says which setting could not be
   honoured.
6. **Given** a workflow whose permission mode is not the runtime's default, **When** the
   project page lists it, **Then** the row says so without anything being opened.

---

### User Story 2 - You can open a workflow and read it (Priority: P2)

A workflow on the project page is three lines: its name, what makes it run, and what
happened last. What it will actually *say* to the agent is not there, and neither is
anything else in the file. Someone clicks the row. The workflow opens: its name, its
trigger in the words the row used, which agent runs it, the settings it carries, and the
prompt in full — the thing that will be sent, verbatim, at nine tomorrow morning.

An agent wrote this one, without asking. Reading it is how the person decides whether to
keep it.

**Why this priority**: An agent can create a workflow in this app without anybody's
approval, and the only counterweight offered today is archiving it — a decision made from
three lines that never show the prompt. Every row already leads somewhere except this
one. It comes before changing anything because you cannot sensibly change a setting on
something you have not read, and because the view is where the change will live.

**Independent Test**: Click a workflow row and confirm the whole file's meaning is on
screen — trigger, agent mode, settings, and the entire prompt body — without opening
Finder or an editor.

**Acceptance Scenarios**:

1. **Given** any workflow on a project page, **When** the reader clicks its row, **Then**
   the workflow opens showing its name, trigger in plain words, agent mode, settings and
   full prompt.
2. **Given** an archived workflow, **When** the reader clicks its row, **Then** it opens
   the same way, and says it is archived and will not run.
3. **Given** a workflow whose file cannot be read, **When** the reader clicks its row,
   **Then** it opens showing the problem and the file's text as it stands, so there is
   something to act on.
4. **Given** an open workflow, **When** its file changes on disk, **Then** what is on
   screen follows the file without the view being closed and reopened.
5. **Given** an open workflow, **When** the reader wants the file itself, **Then** the
   view says where it is and can reveal it in Finder.
6. **Given** an open workflow whose last fire started an agent, **When** the reader
   follows that, **Then** they arrive at the agent, as the row already allows.

---

### User Story 3 - You can change what it is allowed to do (Priority: P3)

The person reading that workflow decides it should never have been able to write files.
They change its permission mode in the view they are already looking at. The file on disk
changes with it — one line, in the front matter, the rest of the file exactly as its
author left it — so the next person to read the repository sees what was decided, and the
change arrives in a pull request like anything else.

**Why this priority**: Writing the setting by hand in an editor already works once story 1
exists, so this is convenience rather than capability — but it is the convenience that
makes the setting real for somebody who has never opened `.agents/workflows`. It is third
because it needs somewhere to live, and that is story 2.

**Independent Test**: Open a workflow, change its permission mode, and confirm the file on
disk now names that mode, that nothing else in the file moved, and that the next fire uses
it.

**Acceptance Scenarios**:

1. **Given** an open workflow, **When** the reader changes its permission mode, **Then**
   the file's front matter is updated and the rest of the file — prompt, triggers,
   comments, keys this version does not recognise — is unchanged.
2. **Given** a workflow whose settings have just been changed, **When** it next fires,
   **Then** the new settings are used, with no restart and no further action.
3. **Given** an open workflow, **When** the reader picks a permission mode, **Then** the
   choices offered are the ones its runtime actually advertises, not a list this app
   invented.
4. **Given** a workflow whose runtime has never been used in that project, **When** the
   reader opens it, **Then** the view says what the setting currently is and that the
   choices are not known yet, rather than offering an empty menu or a wrong one.
5. **Given** a workflow whose file cannot be written — a read-only checkout, a folder that
   has gone — **When** the reader changes a setting, **Then** they are told plainly, and
   nothing is silently held in the app instead.
6. **Given** a running workflow, **When** the reader changes its settings, **Then** the run
   in flight is unaffected and the change applies from the next fire.

---

### User Story 4 - An agent asked for a workflow knows to set this (Priority: P4)

Somebody tells an agent *every morning, check the dependencies for security advisories —
and don't let it change anything*. The agent writes the workflow with that permission mode
in it, because the tool it uses says the setting exists and what it is for. What it tells
the person afterwards names the mode in plain words, not as a line of YAML.

**Why this priority**: Nobody learns the file format; they ask an agent. A setting the tool
does not mention is a setting that gets written by hand or not at all. It is last because
the tool can only describe settings that already exist and are already honoured.

**Independent Test**: Ask an agent to create a workflow that must not change files, and
confirm the file it writes names a permission mode and that its reply says so in words.

**Acceptance Scenarios**:

1. **Given** an agent with the workflow tool, **When** it reads the tool's description,
   **Then** the description states that a workflow may set its permission mode, runtime and
   model, and what happens when it does not.
2. **Given** an agent writing a workflow, **When** it sets a permission mode, **Then** what
   the tool reports back names that mode in the same plain words the project page uses.
3. **Given** an agent listing or reading workflows, **When** it receives them, **Then** each
   one's settings are included.
4. **Given** an agent that writes a setting this version does not recognise, **Then** the
   workflow is still listed and still runs, and the unrecognised setting is left in the file
   untouched.

---

### Edge Cases

- **A mode the runtime does not offer**, because it was misspelled, or the runtime changed
  under it. This must refuse rather than fall back: a workflow asking for plan mode and
  getting the default instead is the one failure this whole feature exists to prevent, and
  it fails in the direction of doing more than was asked.
- **A runtime that is named but not installed**, or not in the catalog at all.
- **A model the runtime no longer offers.** Less dangerous than a mode — a wrong model does
  the wrong quality of work, not the wrong amount of damage — but the reader still has to
  find out which way it was resolved.
- **`triggering` and `standing` modes**, where the agent may already exist. Settings decide
  how an agent is *started*, and an agent that is already running was started under
  somebody else's terms — possibly a person's, in a conversation they are watching.
- **A file with comments in its front matter**, or keys in an order its author chose.
  Writing a setting back must not reformat somebody's file.
- **A file written by a later version**, carrying settings this one does not know.
- **The file changes while the view is open**, including being deleted or renamed.
- **Two windows open on the same workflow**, one of them changing a setting.
- **A read-only checkout**, or a folder that has been unmounted since the page was drawn.
- **A workflow whose front matter cannot be parsed at all** — it still has to be clickable,
  because it is the one most likely to need looking at.
- **A setting changed on an archived workflow**, which will not run either way.
- **A permission mode that removes every prompt.** The row and the view have to make that
  legible at a glance, because it is the setting somebody will regret.

## Requirements *(mandatory)*

### Functional Requirements

**The settings themselves**

- **FR-001**: A workflow MUST be able to state, in its file, the permission mode its agent
  runs in, the runtime that runs it, and the model it uses.
- **FR-002**: Each setting MUST be optional, and a workflow stating none of them MUST behave
  exactly as it does today, so that no file already on disk changes meaning.
- **FR-003**: Settings MUST live in the same metadata block as the trigger and the agent
  mode, so that the whole of what a workflow is stays in one reviewable place in the
  repository.
- **FR-004**: Settings this version does not recognise MUST be kept, listed as unrecognised,
  and MUST NOT stop the workflow running — the rule the trigger format already follows.
- **FR-005**: A setting whose value is malformed MUST make the workflow one that cannot run,
  stated on its row in the same way an unreadable trigger already is.

**Honouring them**

- **FR-006**: When a workflow starts a fresh agent, that agent MUST be started with the
  workflow's stated permission mode, runtime and model.
- **FR-007**: A workflow that states no runtime MUST start on the app's default choice, which
  is what happens today.
- **FR-008**: A workflow whose stated permission mode is not offered by its runtime MUST NOT
  start an agent, and MUST record the refusal naming the setting and the value. Falling back
  to the runtime's default is forbidden: the fallback is always more permissive than what was
  asked for, and nobody is watching.
- **FR-009**: A workflow whose stated runtime is unavailable MUST be refused with that reason,
  rather than started on another one.
- **FR-010**: A workflow whose stated model is unavailable MUST be refused with that reason.
- **FR-011**: Settings MUST apply when a workflow starts an agent. A workflow resuming an
  agent that already exists MUST NOT change that agent's settings, and the fact that they do
  not apply MUST be stated where the settings are shown.
- **FR-012**: A refusal caused by a setting MUST be recorded and surfaced the same way every
  other refusal is, so that a workflow that has stopped running because of a typo is not
  indistinguishable from one whose trigger never matched.

**Seeing a workflow**

- **FR-013**: Clicking a workflow on the project page MUST open that workflow. Every workflow
  MUST be openable this way — archived, over a ceiling, unreadable, or from a later version.
- **FR-014**: The opened workflow MUST show its name, its trigger in plain language, which
  agent runs it, its settings, and its prompt in full.
- **FR-015**: The prompt MUST be shown as it will be sent — complete and unedited — because
  the prompt is the part of a workflow that can do anything, and it is the part the row has
  never shown.
- **FR-016**: A workflow whose file could not be understood MUST still open, stating the
  problem and showing the file's text, so there is something to act on.
- **FR-017**: The opened workflow MUST follow its file: a change on disk MUST be reflected
  without it being closed and reopened.
- **FR-018**: The opened workflow MUST say where its file is and MUST be able to reveal it.
- **FR-019**: Everything the row offers — running it now, archiving it, reaching the agent its
  last run started — MUST be available from the opened workflow too.

**Changing them**

- **FR-020**: The permission mode, runtime and model MUST be changeable from the opened
  workflow, and the change MUST be written to the workflow's file.
- **FR-021**: *Amends FR-032 of 008.* The project page may now change a workflow's settings.
  Its triggers and its prompt body remain unchangeable there: those are the workflow, and
  authoring them stays in the file or with an agent. A setting is a statement about how much
  the workflow is allowed to do, and that is the person's to make wherever they are standing.
- **FR-022**: Writing a setting MUST leave the rest of the file as its author wrote it — the
  prompt, the triggers, the ordering, any comments, and any keys this version does not
  recognise.
- **FR-023**: The choices offered for a setting MUST be the ones its runtime advertises, and
  MUST NOT be a list this app maintains separately.
- **FR-024**: When the choices for a runtime are not known, the current value MUST still be
  shown and stated as unverified, rather than an empty or invented menu being offered.
- **FR-025**: A change that cannot be written MUST say so plainly, and MUST NOT be held in the
  app as though it had been written.
- **FR-026**: A change MUST take effect from the next fire, with no restart, and MUST NOT
  disturb a run in flight.
- **FR-027**: A permission mode that is not the runtime's default MUST be visible on the
  project page row, not only inside the opened workflow.

**The tool**

- **FR-028**: The workflow tool's description MUST state that a workflow may set its
  permission mode, runtime and model, MUST show how, and MUST say what happens when it does
  not.
- **FR-029**: What the tool reports after a write MUST name the settings in the same plain
  words the project page uses, alongside what it already says about the trigger and the agent
  mode.
- **FR-030**: Listing and reading workflows through the tool MUST include their settings.
- **FR-031**: The tool MUST NOT require an agent to state any setting, and MUST NOT write one
  that was not asked for.

### Key Entities

- **Workflow settings**: What a workflow says about how its agent should be started —
  permission mode, runtime, model. Part of the workflow file, therefore part of the
  repository, therefore reviewable. Distinct from workflow state (archived, standing agent,
  last outcome), which is the app's bookkeeping and stays out of the repository.
- **Permission mode**: How much the agent may do without being asked. Advertised by the
  runtime rather than defined by this app, which is why a workflow can name one the runtime
  does not offer and why that has to be a refusal.
- **The opened workflow**: One workflow shown whole — what makes it run, who runs it, under
  what terms, and what it will say. The place a setting is changed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A workflow that must not change files can be made so by adding one line to its
  file, or by one change in the app, and the row says so afterwards without anything being
  opened.
- **SC-002**: Every workflow on a project page opens when clicked. In testing, none — archived,
  broken, unsupported or over a ceiling — is a dead row.
- **SC-003**: Someone can read a workflow an agent wrote, in full, including the prompt, without
  leaving the app.
- **SC-004**: A workflow never runs with a permission looser than the one its file names. In
  testing, every mismatch produces a refusal that names the setting, and zero produce a started
  agent.
- **SC-005**: Changing a setting in the app and reading the file afterwards shows one line
  different and nothing else moved.
- **SC-006**: Every workflow file that exists before this feature behaves identically after it.
- **SC-007**: Somebody who asks an agent for a workflow that must not change files gets one
  whose file says so.
- **SC-008**: From the project page, deciding whether to keep a workflow an agent wrote takes
  one click and no editor.

## Assumptions

- The settings are three front-matter keys beside `on:`, `agent:` and `name:` — the same block,
  the same file, the same reader. `permission-mode:`, `runtime:` and `model:`, named in the
  hyphenated style the trigger names already use.
- The permission mode's values are the runtime's own, passed through as written. This app does
  not define a vocabulary of modes, does not translate between runtimes, and does not try to
  make plan mode on one runtime mean plan mode on another. A workflow is about a project, and a
  project's runtime is a thing the person already chose.
- The choices shown for a setting come from what the runtime last advertised for that project.
  A runtime never used in that folder has nothing to offer yet, which FR-024 is about. Starting
  a session merely to populate a menu is out of scope: it would start a runtime every time
  somebody opened a workflow to read it.
- Settings decide how an agent is started, so in `triggering` mode they do not apply at all, and
  in `standing` mode they apply to the first fire and to any fire that has to start a
  replacement. Changing a live agent's permission mode from underneath a workflow was
  considered and left out: in `triggering` mode that agent is very often one a person is
  sitting in front of, and a workflow silently changing what they are allowed to do is worse
  than the workflow not running.
- The opened workflow is a view within the app, reached by clicking the row, alongside the way
  an agent is opened. Editing the prompt body there is out of scope, per FR-021.
- Writing a setting edits the front matter in place rather than regenerating the file, so that
  comments and ordering survive. This is what FR-022 costs and it is worth it: a person's
  workflow file is a file they wrote.
- The file remains the only source of truth for settings. Nothing about a setting is held in the
  app's own records, which continue to hold only what cannot be in the repository.
- Extra arguments, additional directories and MCP servers are deliberately out of scope. They
  are part of starting an agent and they will want saying eventually; none of them is the thing
  that decides whether an unattended agent can change your files.
- A per-workflow cost limit is out of scope: 010 put limits on the day and on the agent, and
  that is where a runaway workflow is already caught.
- The feature is macOS-only, matching the app.
- The project constitution is an unfilled template, so no project-specific principles constrain
  this specification.
