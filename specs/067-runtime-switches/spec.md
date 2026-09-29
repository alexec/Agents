# Feature Specification: Runtime switches

**Feature Branch**: `agents/work-github-issue-41`

**Created**: 2026-09-29

**Status**: Draft

**Input**: Issue #41, "Investigate each agent runtime's options beyond model and mode". The audit
is in `docs/reference/runtimes.md`, section "Options beyond model and mode". Alex decided on
2026-09-29 which options to show, which the app sets for the person, and which to leave alone.

## Why this feature exists

Each runtime has dozens of options beyond model and mode. Most belong to the person's own
settings files, which the app must not edit (064's constraint), and most are better left
alone. The audit found three things a person reasonably wants to decide once per runtime,
for every agent the app starts on it: whether the agent may use the web, whether the runtime
sends usage data to its vendor, and whether it keeps a memory across conversations. Today
the person can decide none of them in the app, and the app is inconsistent: it switches
Codex's memory off and leaves Claude's and Grok's on.

The audit also found settings where the runtime's default works against the app: agents that
can no longer be picked back up after 30 idle days, a web search that never asks, a
conversation export that could publish work, a runtime that updates itself under a running
agent, a person's own Claude folder that the app hides, and a cost ceiling that Claude could
enforce itself. The app sets these for the person, without a control.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Keep an agent off the web (Priority: P1)

A person working on private code, or wanting reproducible work, turns off web access for a
runtime in **Settings ▸ Agent Runtimes**. Every agent started afterwards on that runtime, on
the Mac or on a server, has no web search and no web fetch. The row says, in plain words,
what the switch reaches for that runtime, and says so when it cannot reach it.

**Why this priority**: It changes what an agent can do, and six of eight runtimes offer a
lever that works on servers too.

**Independent Test**: Turn web access off for Claude. Start a Claude agent and ask it to
search the web for today's news. It reports that it has no web tool, and no web tool call
appears in the conversation. Turn it on again, start another agent, and the same prompt
searches.

**Acceptance Scenarios**:

1. **Given** web access is on (the default) for a runtime, **when** an agent starts, **then**
   it has the runtime's web tools exactly as today.
2. **Given** web access is off for Claude, Codex, Gemini, Antigravity, OpenCode or Grok,
   **when** an agent starts on that runtime, **then** the runtime offers it no web search and
   no web fetch.
3. **Given** web access is off, **when** an agent in a server project starts, **then** the
   same holds on the server.
4. **Given** Cursor, **when** the person looks at its row, **then** the switch is not offered
   and the row says Cursor gives the app no way to turn its web tools off.
5. **Given** Copilot, **when** the person looks at its row before its lever has been measured,
   **then** the switch is not offered and the row says why.
6. **Given** an agent already running, **when** the person changes the switch, **then** its
   current turn is unchanged, and the new value applies when that agent next starts or is
   picked back up.

---

### User Story 2 - Stop sending usage data (Priority: P2)

A person who does not want their runtimes reporting usage to the vendor turns usage data off
per runtime. The row says where the switch cannot win, such as Gemini's own settings file.

**Why this priority**: A privacy choice people expect to make once; four runtimes have a
lever, and it applies on servers too.

**Independent Test**: Turn usage data off for Codex. Start a Codex agent. The settings Codex
reports for that conversation show analytics and feedback off. Turn it on, start another
agent, and they are back to Codex's own default.

**Acceptance Scenarios**:

1. **Given** usage data is on (the default), **when** an agent starts, **then** the runtime
   sends what it sends by its own default, and the app changes nothing.
2. **Given** usage data is off for Claude, Codex, Gemini or Grok, **when** an agent starts,
   **then** the runtime is told not to send usage data, error reports or other non-essential
   traffic to its vendor.
3. **Given** Gemini with usage data off, **when** the person's own Gemini settings turn usage
   statistics on, **then** their own setting wins, and the row says in advance that it will.
4. **Given** Copilot, Cursor, OpenCode or Antigravity, **when** the person looks at the row,
   **then** there is no switch, and the row says the runtime offers nothing to switch.

---

### User Story 3 - Choose whether a runtime remembers (Priority: P2)

A person decides per runtime whether its own memory across conversations is on. It is on by
default for every runtime that has one, Codex included, which the app switches off today.

**Why this priority**: It makes the app consistent, and memory changes how an agent behaves
from one conversation to the next.

**Independent Test**: With memory on for Codex, start a Codex agent: the conversation's
settings show memories on. Turn memory off for Claude, start a Claude agent, and ask it to
remember a fact for next time: it has no memory to write to.

**Acceptance Scenarios**:

1. **Given** memory is on (the default), **when** a Claude, Codex or Grok agent starts,
   **then** the runtime's own memory is on.
2. **Given** memory is off for one of them, **when** an agent starts, **then** its memory is
   off for that conversation, and the person's own settings files are untouched.
3. **Given** Copilot, **when** the person looks at its row, **then** there is no switch, and
   the row says Copilot's memory is set only in Copilot itself.
4. **Given** a runtime with no memory of its own, **when** the person looks at its row,
   **then** no memory switch is shown.

---

### User Story 4 - Settings the app gets right for the person (Priority: P2)

Without any control, the app starts each runtime so that its defaults do not work against the
app: agents stay resumable, web searches ask like fetches do, nothing is published, runtimes
are not replaced under running agents, the person's own Claude folder is used, and Claude
stops itself at an agent's cost ceiling.

**Why this priority**: Each one is a small launch change, and each fixes a real failure found
by the audit.

**Independent Test**: Each item below is checked on its own, in a scratch root, by reading
what the runtime was started with and one behaviour it causes.

**Acceptance Scenarios**:

1. **Given** a Claude or Gemini agent idle for longer than 30 days, **when** the person picks
   it back up, **then** its conversation is still there, as long as the app still keeps the
   agent.
2. **Given** an OpenCode agent, **when** it wants to search the web, **then** it asks first, as
   it does before fetching a page.
3. **Given** a Copilot agent, **when** it starts, **then** its remote control and export to
   GitHub are off.
4. **Given** a Grok agent running, **when** a newer Grok is released, **then** the running
   Grok is not replaced under it.
5. **Given** a person whose Claude folder is not `~/.claude`, **when** the app starts Claude,
   **then** Claude uses their folder: their settings, sign-in and conversations.
6. **Given** a Claude agent in a server project, **when** it runs a shell command, **then** the
   command's environment carries no sign-in token.
7. **Given** an agent with a cost ceiling on Claude, **when** its spending reaches the ceiling,
   **then** Claude stops the turn itself, and the app's own stop still applies.
8. **Given** Grok's shared leader process and its workflows, and Antigravity's folder trust,
   **when** each has been measured as described in FR-014 to FR-016, **then** the app sets it;
   until then the app starts them as today and the reference page says so.

### Edge Cases

- A runtime update removes or renames the setting a switch uses: the app's check of each
  runtime's options notices it, and the row says the switch no longer reaches the runtime
  rather than claiming it took effect.
- A server whose installed Grok is too old to know a setting: the agent still starts, with the
  runtime's own default, and nothing claims the switch applied.
- An agent picked back up after the switch changed: it gets the new value.
- A workflow or another agent starts an agent: the switches apply exactly as for an agent the
  person starts.
- Web access off and a project's own MCP server that fetches web pages: the switch covers the
  runtime's own web tools only, and the row says so.
- The person turns memory off, then on: what the runtime remembered before is still there;
  the switch never deletes a memory.

## Requirements *(mandatory)*

### Functional Requirements

**The switches**

- **FR-001**: Settings ▸ Agent Runtimes MUST offer, per runtime, a **Web access** switch, a
  **Usage data** switch and a **Memory** switch, where that runtime has a lever for them (see
  "Where each switch reaches"). All three are on by default.
- **FR-002**: Where a runtime has no lever, its row MUST say so in one sentence instead of
  showing a switch.
- **FR-003**: A switch MUST apply to every agent that starts or is picked back up on that
  runtime after the change, on the Mac and in server projects, whoever starts it (the person,
  a workflow or another agent). A turn in progress keeps what it started with.
- **FR-004**: The app MUST NOT write to any runtime's own settings files to apply a switch.
  Every switch is applied through what the app starts the runtime with.
- **FR-005**: **Web access** off MUST remove the runtime's own web search and web fetch tools
  from the agent, not only refuse them.
- **FR-006**: **Usage data** off MUST tell the runtime not to send usage data, error reports or
  other non-essential traffic to its vendor, as far as the runtime lets a caller say so. Where
  the person's own settings can override it (Gemini), the row MUST say so.
- **FR-007**: **Memory** on MUST leave the runtime's own memory on, including Codex's, which
  the app switches off today. **Memory** off MUST switch it off for that conversation without
  deleting anything the runtime remembered.
- **FR-008**: The iPhone and iPad MUST show each switch's state read-only, as other runtime
  settings.
- **FR-009**: The reference page MUST list, per runtime, what each switch reaches, and the
  handshake check MUST keep noticing a runtime's new or vanished options.

**Set for the person**

- **FR-010**: The app MUST start Claude and Gemini so that they keep a conversation at least as
  long as the app keeps the agent that owns it. When the app keeps agents without limit, the
  runtime keeps conversations for the longest period it allows.
- **FR-011**: The app MUST start OpenCode so that it asks before searching the web.
- **FR-012**: The app MUST start Copilot with its remote control and its export to GitHub off.
- **FR-013**: The app MUST start Grok with its self-update off.
- **FR-014**: Once measured that it keeps the app's **Default** permission mode in force and
  that Grok still starts, the app MUST start Grok without its shared leader process.
- **FR-015**: Once measured that it removes Grok's `workflow` tool from the agent without
  removing a work tool, the app MUST start Grok with its workflows and goals off, and the
  `workflow` residue MUST leave the scoped-tools page.
- **FR-016**: Once measured that Antigravity's own question about a project's hooks reaches the
  person as a card they can answer on the Mac and phone, the app MUST stop trusting
  Antigravity's folders on the person's behalf. Gemini keeps its folder trust, which the app's
  tools need.
- **FR-017**: The app MUST pass a person's own Claude folder setting through to Claude, while
  still keeping out every other variable a parent Claude session sets.
- **FR-018**: In a server project, the app MUST start Claude so that the relay's stand-in
  sign-in token is not passed on to the shell commands, hooks and tools Claude runs.
- **FR-019**: When an agent on Claude has a cost ceiling, the app MUST tell Claude that
  ceiling, so that Claude stops the turn itself at it. The app's own stop is unchanged.

### Where each switch reaches

| Runtime | Web access | Usage data | Memory |
| --- | --- | --- | --- |
| Claude | Its web search and fetch tools | Its telemetry, error reports and non-essential traffic | Its auto memory |
| Codex | Its web search | Its analytics and feedback | Its memories |
| Gemini | Its web search and fetch tools | Its usage statistics; the person's own Gemini settings win | No memory switch: its memory is the context files the app already manages |
| Antigravity | Its web search and page reading tools | Nothing to switch | No memory of its own |
| OpenCode | Its web search and fetch tools | Nothing to switch | No memory of its own |
| Grok | Its web search, fetch and page tools | Its telemetry | Its memory |
| Copilot | Not offered until its address rules are measured to work with the app | Nothing to switch | Set only in Copilot itself |
| Cursor | No way for the app to turn it off | Nothing to switch | No memory of its own |

### Key Entities

- **Runtime switches**: per runtime, three on/off values (web access, usage data, memory),
  each on by default, kept with the app's other per-runtime settings and read when an agent
  starts or is picked back up.
- **Switch reach**: per runtime and switch, whether the app can apply it, and the sentence the
  row shows when it cannot, or when the person's own settings can override it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With web access off, 0 web tool calls occur across one agent on each of the six
  runtimes with a lever, each asked to look something up on the web, on the Mac and on a
  server.
- **SC-002**: With each switch at its default, every runtime starts with exactly what it
  started with before this feature, except Codex's memory, which is on.
- **SC-003**: A person can find and change any of the three switches for a runtime in under
  30 seconds from the Settings window.
- **SC-004**: Every runtime without a lever for a switch shows a sentence saying so; no row
  shows a switch that does nothing.
- **SC-005**: A Claude and a Gemini agent whose conversation is older than 30 days can be
  picked back up.
- **SC-006**: Nothing in any runtime's own settings folder in the person's home changes when a
  switch is used (checked by comparing the folders before and after).

## Docs *(mandatory)*

- `docs/reference/runtimes.md`: change the "Decided" column from **planned** to done as each
  switch and setting lands, and add a line for each switch to the runtime table.
- `docs/reference/settings.md`: add the three switches under Settings ▸ Agent Runtimes.
- `docs/explanation/scoped-tools.md`: change it when FR-015 removes Grok's `workflow` residue.

## Assumptions

- Sandbox options are decided by #40 (spec 064) and are not part of this feature.
- Out of scope, by Alex's decision: a default effort for new agents, Cursor's effort, context
  and fast as separate options, and commit attribution.
- The items listed as **Measure** in the reference page (Codex's browser and computer-use
  tools, OpenCode's MCP timeout, Grok's folder trust on servers, Cursor's shared model choice)
  are follow-ups, not part of this feature.
- A switch is per runtime, not per agent: the decisions asked for a Settings control, and the
  options a runtime offers under the prompt stay per agent as today.
- Grok, Copilot and Cursor on a server are the copies installed there; a switch reaches them
  through what the app starts them with, as on the Mac.
- Antigravity runs on the Mac only today; its switches apply on servers when it does.
