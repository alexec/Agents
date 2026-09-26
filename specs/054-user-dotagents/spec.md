# Feature Specification: One Set of Skills, Instructions, MCP Servers and Plugins for Every Agent

**Feature Branch**: `agents/consider-how-might-have`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Consider how we might have a shared user config for all agents. E.g. ~/.agents/skills and replicate this for ~/.claude/skills. Similar to how projects work, but for the user." Widened the same day: "I'd like to be able to configure my MCP servers and plugins once, in ~/.agents and have every agent runtime use them, so I manage them all in one place. Adding a new agent automatically adds the MCPs (and plugins) to that agent." Worked up in [proposal.md](proposal.md), whose Decided section holds Alex's calls.

## Why this feature exists

A project added to the app already gets the dotagents layout: `AGENTS.md` and `.agents/skills`
are the one real copy, and Claude — the one runtime that reads neither — gets links to them. So
a skill written once for a project reaches every agent that works in it.

Nothing does that for the person. Skills and instructions that should follow them into every
project live in a different folder for each runtime: `~/.claude/skills` for Claude,
`~/.grok/skills` for Grok, and so on. A skill installed for one is missing from the others. On
this Mac today, four skills sit in `~/.agents/skills` (put there by the community `skills`
installer), Grok sees them through links that installer made, and Claude sees none of them.

MCP servers and plugins are worse off. Each runtime keeps its own list of MCP servers in its
own file and format (`~/.claude.json`, `~/.codex/config.toml`, `~/.cursor/mcp.json`, …), and its
own plugin folder or marketplace, so a server or plugin set up for one agent has to be set up
again, by hand, for every other one — and again for each agent added later.

This feature gives the home folder the same layout: `~/.agents` holds the person's skills,
personas, instructions, MCP servers and plugins once, and every runtime the app starts finds
them there — directly, through a link the app keeps in place, or handed to it by the app when
its session is made.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A skill in ~/.agents reaches every agent (Priority: P1)

The person puts a skill folder in `~/.agents/skills` — by hand, or with `npx skills add`. The
next agent they start, on any runtime, can use it, in any project.

**Why this priority**: This is the feature. Everything else protects what is already there.

**Independent Test**: With only this story built, put a skill in `~/.agents/skills` on a
scratch home, start a Claude agent through the app, and ask it which skills it has: the new one
is listed. Repeat for each supported runtime.

**Acceptance Scenarios**:

1. **Given** a skill in `~/.agents/skills/<name>` and no `~/.claude/skills/<name>`, **When** an
   agent is started on Claude, **Then** Claude offers that skill, through a link at
   `~/.claude/skills/<name>`.
2. **Given** claude.ai's synced skills in `~/.claude/skills/synced`, **When** the layout is
   applied, **Then** `synced` and everything in it is exactly as before, and Claude still offers
   the synced skills.
3. **Given** a skill added to `~/.agents/skills` while the app is running, **When** the next
   agent starts, **Then** that agent has it, without restarting the app.
4. **Given** a runtime that already reads `~/.agents/skills` itself, **When** the layout is
   applied, **Then** no link is made for that runtime.

---

### User Story 2 - Instructions written once apply everywhere (Priority: P1)

The person writes how they like to work in `~/.agents/AGENTS.md`. Every agent reads it, in every
project, on every runtime that has a place for personal instructions.

**Why this priority**: Alex chose skills and instructions together; instructions are the other
half of "shared user config".

**Independent Test**: Write a distinctive line in `~/.agents/AGENTS.md` on a scratch home, start
an agent on each runtime, and ask what personal instructions it was given.

**Acceptance Scenarios**:

1. **Given** `~/.agents/AGENTS.md` and no `~/.claude/CLAUDE.md`, **When** the layout is applied,
   **Then** `~/.claude/CLAUDE.md` is a link to it.
2. **Given** `~/.agents/AGENTS.md` and no `~/.codex/AGENTS.md`, **When** the layout is applied,
   **Then** `~/.codex/AGENTS.md` is a link to it.
3. **Given** no `~/.agents/AGENTS.md` and no personal instructions anywhere, **When** the layout
   is applied, **Then** `~/.agents/AGENTS.md` is created, short, saying what it is for, and the
   links point at it.

---

### User Story 3 - What the person already has moves in, and nothing is lost (Priority: P2)

The person already has skills in `~/.claude/skills` and a `~/.claude/CLAUDE.md`. The first time
the layout is applied, those move into `~/.agents` and are linked back, so Claude sees exactly
what it saw before and every other agent now sees them too.

**Why this priority**: Adopting what exists is what makes the shared copy real on day one; Alex
chose to move rather than leave in place.

**Independent Test**: On a scratch home with a real skill folder and a `CLAUDE.md` under
`~/.claude`, apply the layout; the files are now under `~/.agents`, `~/.claude` holds links to
them, and their contents are byte-for-byte unchanged.

**Acceptance Scenarios**:

1. **Given** a real folder `~/.claude/skills/<name>` and no `~/.agents/skills/<name>`, **When**
   the layout is applied, **Then** the folder is moved to `~/.agents/skills/<name>` and
   `~/.claude/skills/<name>` is a link to it.
2. **Given** a real `~/.claude/skills/<name>` and a different `~/.agents/skills/<name>`, **When**
   the layout is applied, **Then** both are left exactly as they are.
3. **Given** a real `~/.claude/CLAUDE.md` and no `~/.agents/AGENTS.md`, **When** the layout is
   applied, **Then** the file moves to `~/.agents/AGENTS.md` and `~/.claude/CLAUDE.md` links to it.
4. **Given** a real `~/.claude/CLAUDE.md` and a real `~/.agents/AGENTS.md`, **When** the layout is
   applied, **Then** both are left exactly as they are.

---

### User Story 4 - The app stays out of the way of other tools and of the person (Priority: P2)

Other tools write to these folders too: the `skills` installer, claude.ai sync, Cursor's own
skill sync. And the person may undo a link on purpose. The app keeps its links right without
fighting any of them.

**Why this priority**: A layout that fights the person or another tool is worse than none.

**Independent Test**: On a scratch home, run the `skills` installer for Claude and Grok, delete
one of the app's links, remove a skill from `~/.agents/skills`, then apply the layout twice;
check each outcome below.

**Acceptance Scenarios**:

1. **Given** a link the `skills` installer already made at `~/.claude/skills/<name>` pointing into
   `~/.agents/skills`, **When** the layout is applied, **Then** it is left as it is.
2. **Given** a link the app made that the person has since deleted, **When** the layout is
   applied again, **Then** it is not put back.
3. **Given** a skill removed from `~/.agents/skills`, **When** the layout is applied, **Then**
   links into `~/.agents/skills` that now point at nothing are removed, and no other link is.
4. **Given** the layout already applied, **When** it is applied again with nothing changed,
   **Then** nothing on disk changes.

---

### User Story 5 - The person can see which agents share which skills (Priority: P3)

In Settings ▸ Agents, a "Your skills" section lists the person's skills and says, for each,
which runtimes can use it, and names any skill left out because of a clash. It is read-only,
with Reveal in Finder.

**Why this priority**: Useful, but the layout works without it. Its look is drawn and approved
before it is built.

**Independent Test**: Open Settings ▸ Agents on a scratch root with a clash on disk; the list
shows every skill and names the clash.

**Acceptance Scenarios**:

1. **Given** skills in `~/.agents/skills` and a clash in `~/.claude/skills`, **When** the person
   opens Settings ▸ Agents, **Then** a "Your skills" section lists every skill in `~/.agents/skills` with the runtimes that
   can use it, and the clashing skill is named with where each copy is.
2. **Given** the section, **When** the person chooses Reveal in Finder on a skill, **Then**
   Finder opens on that skill's folder in `~/.agents/skills`.

---

### User Story 6 - MCP servers set up once reach every agent (Priority: P1)

The person lists their MCP servers once, in `~/.agents/mcp.json`. Every agent the app starts,
on every runtime — including a runtime added to the app later — has those servers, with no
per-runtime setup.

**Why this priority**: Alex asked for it by name: MCP servers managed in one place, and a new
agent getting them without anyone adding them.

**Independent Test**: On a scratch home, put one stdio server in `~/.agents/mcp.json`, start an
agent on each runtime through the app, and ask it to list its MCP tools: the server's tools are
there on each.

**Acceptance Scenarios**:

1. **Given** a server in `~/.agents/mcp.json`, **When** an agent starts on any runtime, **Then**
   the server is in the `mcpServers` the app sends with that session's `session/new`, beside the
   app's own servers and any the person chose for that agent.
2. **Given** a server added to `~/.agents/mcp.json` while the app is running, **When** the next
   agent starts, or a stopped one is resumed, **Then** it has the server, without restarting the
   app.
3. **Given** an http or sse server and a runtime that does not say it supports that transport,
   **When** an agent starts on it, **Then** the server is left out for that agent, the reason is
   logged, and every other server still goes.
4. **Given** `~/.agents/mcp.json` that is not valid, **When** an agent starts, **Then** it starts
   without the personal servers and the problem is shown to the person, not swallowed.
5. **Given** a runtime the app did not support when `~/.agents/mcp.json` was written, **When** it
   is added and an agent started on it, **Then** that agent has the servers too.

---

### User Story 7 - Plugins installed once reach every agent (Priority: P2)

The person puts a plugin folder in `~/.agents/plugins`. Every agent the app starts, on each
runtime that can load a plugin of that shape, has it.

**Why this priority**: Asked for alongside MCP, but runtimes load plugins in more different ways
than servers, so it can follow the MCP half.

**Independent Test**: On a scratch home, put a plugin holding one command in
`~/.agents/plugins/<name>`, start an agent on each runtime, and ask whether it has that command.

**Acceptance Scenarios**:

1. **Given** a plugin in `~/.agents/plugins/<name>` with a `.claude-plugin/plugin.json`, **When**
   an agent starts on Claude, Grok, Codex, Cursor or Copilot, **Then** that runtime loads it, by
   whichever means the probe settled for it (FR-021).
2. **Given** a runtime with no known way to load a personal plugin, **When** an agent starts on
   it, **Then** it starts without the plugins, and Settings says that runtime does not get them.
3. **Given** a plugin removed from `~/.agents/plugins`, **When** the next agent starts, **Then** no
   runtime is given it, and any link the app made for it is gone.

---

### Edge Cases

- **The runtime is not installed.** Its folder (`~/.codex`, `~/.grok`, …) does not exist: no
  folder is created for it and no link is made.
- **A skill folder has no `SKILL.md`.** It is still linked; what counts as a skill is the
  runtime's call, not the app's.
- **`~/.claude/skills` is itself a link** (the person linked the whole folder somewhere): left
  alone; per-skill links are not made inside someone else's link.
- **`~/.agents` is a link** (to a dotfiles repo, say): followed, and treated as the real copy.
- **A skill name clashes with a managed folder**, such as a skill called `synced`: not linked for
  that runtime, and logged.
- **A move fails half way** (permissions, a full disk): that one step is logged and skipped; the
  rest still runs, and the original is still where it was.
- **The app's own scratch roots and test runs** must never touch the real home folder; the home
  folder they lay out is the one they were given.
- **Servers (037)**: a Linux server gets the same layout on its own home, from its own agentsd;
  the Mac's `~/.agents` is not copied there.
- **An MCP server with the same name as one the app adds** (its own tools server) or one chosen
  for that agent: the agent's own choice wins over the personal one, the app's own always wins,
  and the one dropped is logged.
- **The same MCP server also set up in a runtime's own config** (`~/.claude.json`, say): the
  runtime may then have it twice. The app does not edit the runtime's config; what the runtime
  does with the duplicate is recorded by the probe, and Settings names the duplicate.
- **Secrets in `mcp.json`** (tokens in `env` or `headers`): passed to the runtime as written,
  never logged, never sent to the phone or a server.
- **An agent run outside the app** (the runtime's own CLI in a terminal) does not get the
  personal MCP servers or plugins; they reach only agents the app starts.

## Clarifications

### Session 2026-09-25

- Q: How far does the home layout go? → A: Skills and instructions both.
- Q: Real skills already in `~/.claude/skills`? → A: Moved into `~/.agents/skills` when the name
  is free, and linked back; clashes left alone.
- Q: Should the app show the shared skills? → A: Yes, a read-only "Your skills" section in
  Settings ▸ Agents.
- Q: MCP servers and plugins — this spec or a new one? → A: This one.
- Q: Should personal MCP servers reach only agents the app starts, or also each runtime's CLI
  run by hand? → A: Only agents the app starts: the app passes them in each session's request,
  and no runtime's own config file is written.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST treat `~/.agents/AGENTS.md`, `~/.agents/skills/` and
  `~/.agents/personas/` as the one real copy of the person's instructions, skills and personas,
  creating the two folders when they are missing.
- **FR-002**: For each runtime that does not read a skill from `~/.agents/skills` itself, the app
  MUST place one link per skill in that runtime's personal skills folder, pointing at
  `~/.agents/skills/<name>`. It MUST NOT replace the runtime's skills folder itself with a link.
- **FR-003**: For each runtime that reads personal instructions from its own file and not from
  `~/.agents/AGENTS.md`, the app MUST link that file to `~/.agents/AGENTS.md`. Per the probe (research R1): Claude
  (`~/.claude/CLAUDE.md`), Codex (`~/.codex/AGENTS.md`), Grok (`~/.grok/AGENTS.md`) and Copilot
  (`~/.copilot/copilot-instructions.md`). Cursor has no such file and gets none.
- **FR-004**: Which runtimes need which links MUST be settled by a probe on a scratch home for
  each supported runtime (Claude, Codex, Grok, Cursor, Copilot), recorded with the plan, and
  never guessed from a binary's strings alone.
- **FR-005**: A real skill folder in a personal skills folder the app links into (Claude's only,
  research R3) MUST be moved to
  `~/.agents/skills/<name>` and linked back when that name is free there; when it is not, both
  MUST be left untouched.
- **FR-006**: A real personal instructions file (`~/.claude/CLAUDE.md` etc.) MUST be moved to
  `~/.agents/AGENTS.md` and linked back when `~/.agents/AGENTS.md` does not exist; when it does,
  both MUST be left untouched. Only the first such file found moves.
- **FR-007**: The app MUST NOT write inside, move or remove anything that another tool manages:
  `~/.claude/skills/synced`, any folder marked by a `.bucket-*` or `.sync-manifest.json`,
  `~/.cursor/skills-cursor`, and `~/.agents/.skill-lock.json`.
- **FR-008**: The app MUST remove only links that point into `~/.agents/skills/` and whose target
  no longer exists. It MUST NOT remove any other file or link.
- **FR-009**: A link the app placed and the person later removed MUST NOT be placed again.
- **FR-010**: The layout MUST be reconciled when the daemon starts and again before each runtime
  session is made, so a skill added since is present for the next agent.
- **FR-011**: Applying the layout when it is already in place MUST change nothing on disk.
- **FR-012**: Each step MUST be attempted on its own; a step that fails MUST be logged and MUST
  NOT stop the others or stop the agent from starting.
- **FR-013**: Links MUST be relative, so a home folder restored from a backup or moved keeps
  working.
- **FR-014**: The existing rule that a project is never the home folder or anything above it
  MUST stay: project layout and home layout never act on the same folder.
- **FR-015**: A scratch root or test run MUST only ever lay out the home folder it was given,
  never the real one.
- **FR-016**: Settings ▸ Agents MUST show a read-only "Your skills" section: each skill in
  `~/.agents/skills`, the runtimes that can use it, any clash left alone and where both copies
  are, and Reveal in Finder for each skill.
- **FR-017**: `~/.agents/mcp.json` MUST be the one real list of the person's MCP servers, in the
  common `{"mcpServers": {"<name>": {…}}}` shape: `command`, `args`, `env` for stdio; `type`
  (`http` or `sse`), `url`, `headers` for the others. The app MUST NOT create it with any servers
  in it.
- **FR-018**: The app MUST read `~/.agents/mcp.json` before each `session/new` and `session/load`
  it sends, on every runtime, and add its servers to that request's `mcpServers`. It MUST NOT
  write any runtime's own MCP config.
- **FR-019**: An http or sse server MUST be sent only to a runtime whose `initialize` reply
  advertises that transport in `mcpCapabilities`; one left out MUST be logged with the reason.
  This applies to every server the app sends, not only personal ones.
- **FR-020**: When names clash, the app's own servers MUST win, then the servers chosen for that
  agent, then the personal ones; each server dropped MUST be logged.
- **FR-021**: `~/.agents/plugins/<name>/` MUST be the one real copy of the person's plugins. For
  each runtime, the app MUST hand them over by the means the probe (FR-004) settles — session
  metadata where the runtime takes it, a link or an index file in the runtime's own personal
  plugin place where it does not — and MUST NOT copy a plugin's files.
- **FR-022**: The probe (FR-004) MUST also settle, for each supported runtime: that it uses MCP
  servers passed in `mcpServers`, which transports it takes, what it does with a server named
  in both the request and its own config, and how, if at all, it loads a personal plugin.
- **FR-023**: `mcp.json` values MUST NOT be written to any log, event, the phone bridge or a
  server.
- **FR-024**: The "Your skills" section (FR-016) MUST also list the personal MCP servers and
  plugins, with the runtimes that get each, any left out and why, and any problem reading
  `mcp.json`.

### Key Entities

- **Personal layout**: the `~/.agents` folder — instructions, skills, personas — the one real copy.
- **Runtime link rule**: for one runtime, which personal skills folder and which instructions
  file it reads, and so which links it needs. Settled by the probe (FR-004).
- **Placed link record**: the links the app has placed, so one the person removed is not put
  back (FR-009).
- **Personal MCP server**: one entry in `~/.agents/mcp.json` — a name and how to reach it.
- **Personal plugin**: one folder in `~/.agents/plugins`, and for each runtime, how it is handed
  over (FR-021).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A skill added to `~/.agents/skills` is offered by an agent on every supported
  runtime, in any project, the next time one is started — with no step by the person beyond
  adding the skill.
- **SC-002**: A line added to `~/.agents/AGENTS.md` is in the personal instructions of every
  runtime that has personal instructions, the next time an agent starts.
- **SC-003**: Across all acceptance scenarios, no file the person or another tool wrote is lost
  or has its contents changed; every moved file is byte-identical in its new place.
- **SC-004**: Applying the layout twice in a row changes nothing the second time.
- **SC-005**: Starting an agent is no slower that anyone can notice: the reconcile before a
  session adds under 50 ms with 100 skills on disk.
- **SC-006**: The whole suite of layout tests runs against scratch homes only; the real home
  folder is unchanged by a test run.
- **SC-007**: An MCP server added to `~/.agents/mcp.json` is usable by an agent on every
  supported runtime the next time one is started, and by an agent on a runtime added later, with
  no step by the person beyond editing that file.
- **SC-008**: A plugin added to `~/.agents/plugins` is loaded by every runtime the probe found a
  way for, the next time an agent starts on it.

## Docs *(mandatory)*

- `docs/how-to/share-skills-across-agents.md` — add: put a skill or an instruction in
  `~/.agents` once and every agent has it; what moves the first time; how to opt a skill out
  (delete its link).
- `docs/explanation/projects-hosts-worktrees.md` — change: name the personal layout beside the
  project layout, and which one wins (the project's, as each runtime already does).
- `docs/reference/settings.md` — change: the "Your skills" section in Settings ▸ Agents.
- `docs/reference/runtimes.md` — change: for each runtime, where it reads personal skills,
  instructions and plugins, which links the app makes, and which MCP transports it takes.
- `docs/how-to/share-mcp-servers-and-plugins.md` — add: list MCP servers once in
  `~/.agents/mcp.json` and put plugins in `~/.agents/plugins`; they reach agents the app starts,
  not a runtime's CLI run by hand; what happens to a server also in a runtime's own config.

## Assumptions

- `~/.agents` follows the dotagents convention and the community `skills` installer's use of it;
  the app joins that convention rather than inventing its own folder.
- Each runtime already merges project skills and instructions with personal ones, with the
  project's taking precedence; the app does not change that order.
- Codex reads personal skills from `~/.agents/skills` itself (its documented user scope), so it
  needs only the instructions link; the probe confirms this.
- Personas have no runtime that reads them from a personal folder today; the folder is created
  for the person and for the router to name, with no links.
- A clash is left for the person to sort out; the app does not merge, rename or pick a winner.
- Servers are laid out on their own home by their own daemon; syncing the Mac's `~/.agents` to
  them is out of scope.
- MCP servers already set up in a runtime's own config are not imported into `~/.agents/mcp.json`;
  the person copies across the ones they want shared. Importing is a later question, once the
  probe shows how runtimes treat a server listed in both places.
- `.claude-plugin/plugin.json` is the plugin shape the app expects, because Claude, Grok, Codex,
  Cursor and Copilot all read it; Gemini's extensions are a different shape and not covered.
- Personal MCP servers and plugins, like skills, sit below the project's own: a project's
  `.mcp.json` or plugin of the same name is the runtime's to prefer.
