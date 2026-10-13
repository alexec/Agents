# Feature Specification: An agent writes a provider's tool map or commands

**Feature Branch**: `agents/issue-858-at-add`

**Created**: 2026-10-12

**Status**: Draft

**Input**: Issue #858, "An agent writes a provider's tool map or commands at Add Provider".
Alex chose this (2026-10-12) over an agent as a fallback when a call fails, and over an agent
for every call.

## Why this feature exists

A workspace provider (#691) is an MCP server that follows the
[provider contract](../691-workspace-providers/contracts/provider-contract.md). A server that
does not follow it can still be used, with a [tool map](../691-workspace-providers/contracts/tool-map.md).
A CLI can be used with the [command provider](../691-workspace-providers/contracts/command-provider.md).
Today the person must write the map or the commands by hand. To do that, they read the
server's `tools/list` or the CLI's `--help`, learn the map's paths, and try again until the
check passes. That is slow, and most people will stop.

An agent can read the same text and write the map. This feature puts that agent in the Add
Provider sheet, **at authoring time only**:

- The agent reads what the control plane gives it: the server's tools, or the CLI's help.
- It writes a tool map or a command-provider config.
- The control plane checks the draft with one list, as the sheet does now.
- The person reads the draft and the list, and accepts it with **Add**.

After that, nothing changes from #691. Start and Stop stay deterministic, fast and free. They
call the map, not an agent. No agent holds cloud credentials, at authoring or at run time.

## Clarifications

### Session 2026-10-12 (Alex)

- Q: The layout of the agent's part of the sheet? → A: **Write It for Me**, a button in the
  MCP server form and the Your commands form. The sheet shows the agent's steps, then the draft
  in the form's own fields, with the one list it got. **Add** accepts it (layouts L10).
- Q: The Remote and the web page? → A: They have no Providers page (#691 L7), so they get
  nothing: **by design**.
- Q: Which runtime, and which host? → A: The **default runtime**, with a runtime menu in the
  sheet. It runs on the **host on the control plane's machine**, because the server and the
  CLI must be read there. It gets a scratch folder, no project, and only the writer's tools.
- Q: May the agent call start or stop to prove a map? → A: **Only when the person says yes,
  each time.** The agent may ask for one start or one stop of a workspace. The sheet asks the
  person first, with the workspace and its cost. Without a yes, nothing is called.
- Q: How do secrets reach the agent? → A: **They do not.** The control plane connects to the
  server, runs the help and runs the check itself, with the secrets typed in the sheet. The
  agent sees only the output, with each secret's value replaced by its name.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A map for an MCP server that does not follow the contract (Priority: P1)

Alex adds DigitalOcean's own MCP server. Its tools are `droplet-list`,
`droplet-actions-power-on` and so on, not the contract's. Alex types the command and the token,
and presses **Write It for Me**. The sheet shows "Writing… read 41 tools · tried a list". After
a short time the Tool map field holds a map, and under it "✓ Listed 3: agents-devbox (running),
build-box (stopped), scratch-1 (stopped)". Alex reads the map and presses **Add**. The provider
is added as it is today.

**Why this priority**: it is the case that made Alex ask for this. Without it, a server that
does not follow the contract needs a person who can write JSON paths.

**Independent Test**: on a scratch control plane, add a test MCP server with non-contract tool
names (the test server of #691 with renamed tools). Press Write It for Me with a stand-in
runtime that writes a fixed map. See the steps, the draft, the list line, and the provider
added with that map.

**Acceptance Scenarios**:

1. **Given** the MCP server form with a command or an address, **When** Alex presses
   **Write It for Me**, **Then** the control plane connects to the server, reads `tools/list`,
   and starts the writing agent with those tools. The sheet shows a step line with a spinner
   and **×**.
2. **Given** the agent sends a draft, **When** the control plane checks it, **Then** it checks
   as at Add (every named tool is in `tools/list`, the paths parse) and calls one list. The
   result goes back to the agent. The agent may change the draft and check again.
3. **Given** a draft that passed its check, **When** the agent ends, **Then** the Tool map field
   holds the draft, pretty-printed, and the sheet shows the list line and "Written by
   ‹runtime›. Read it before you add it." The field stays editable.
4. **Given** the draft in the field, **When** Alex presses **Add**, **Then** the provider is
   added as in #691: connected, checked and listed again. The record notes that an agent wrote
   the map, which runtime, and when.
5. **Given** the server already follows the contract, **When** Alex presses Write It for Me,
   **Then** no agent starts. The sheet says "It follows the contract: it needs no map."
6. **Given** a server the shipped DigitalOcean map fits (FR-072 of #691), **When** Alex presses
   Write It for Me, **Then** no agent starts. The shipped map fills the field, with "Agents
   ships this map."
7. **Given** Alex pressed **Add** and the server refused with "It isn't a workspace provider: it
   has no … tool", **Then** the refusal has a **Write a Tool Map** button, which does
   scenario 1.

---

### User Story 2 - Commands for a CLI (Priority: P1)

Alex's company has a CLI, `cws`, for its workspaces. Alex picks **Your commands**, types `cws`
in a new **CLI** field, and presses **Write It for Me**. The agent reads `cws --help`, then
`cws list --help` and `cws start --help`. It writes a config with `list`, `columns`, `start`,
`stop` and `ssh`. The control plane runs the draft's list once. The sheet shows the config in
the form's fields and "✓ Listed 2: devstack-1 (running), devstack-2 (stopped)". Alex presses
**Add**.

**Why this priority**: most providers have a CLI (#691), and a CLI that no preset covers has
the same problem as a server with no contract.

**Independent Test**: on a scratch control plane, put a fake `cws` script on the PATH that
prints help and a list. Press Write It for Me with a stand-in runtime. See the help calls in
the steps, the config in the fields, and the list line.

**Acceptance Scenarios**:

1. **Given** the Your commands form with a CLI name, **When** Alex presses Write It for Me,
   **Then** the control plane runs `‹cli› --help` where the commands will run, and the agent
   starts with its output.
2. **Given** the agent asks for more help, **When** it names a subcommand, **Then** the control
   plane runs `‹cli› ‹subcommand…› --help` and gives back its output. It runs nothing else on
   the agent's word.
3. **Given** a draft config, **When** it is checked, **Then** its `list` (or each workspace's
   `status`) runs once, through the command provider, as at Add. It runs only if it passes the
   safe-command rule (FR-014). Otherwise the sheet shows the command and a **Run Check** button
   for the person.
4. **Given** a draft that passed, **When** the agent ends, **Then** the form shows it in its
   fields. A config that the form's fields can't hold (one with `list` and `columns`) shows as
   JSON in a **Config** editor in place of the fields.
5. **Given** the CLI is not installed where the control plane runs, **Then** no agent starts.
   The sheet says "‹cli› isn't installed where the control plane runs", as #691 says it.
6. **Given** the CLI matches a preset (`docker`, `doctl`, `gh`, `coder`, `gcloud`), **Then** no
   agent starts. The sheet says "Agents has a preset for ‹cli›" with a button that opens that
   kind's form.

---

### User Story 3 - Prove start and stop, when the person says yes (Priority: P2)

The list proves only the list. When the agent is not sure of the start or stop arguments, it
asks to try one. The sheet shows "Claude wants to start scratch-1 on DigitalOcean to prove the
map. $0.03/h while running." with **Don't** and **Start It**. Alex presses Start It. The
workspace starts, and the agent sees the result. Then it asks to stop it, and Alex says yes
again.

**Why this priority**: a map with a wrong start is found only when Alex presses Start later.
But a start costs money and changes a machine, so it is the person's choice every time.

**Independent Test**: with a stand-in runtime that asks for a start, see the question in the
sheet. Press Don't and see no call to the server. Press Start It and see one call.

**Acceptance Scenarios**:

1. **Given** the agent asks to start or stop a workspace, **Then** the sheet shows the question
   with the workspace's name, the provider, and its cost when the list gave one. Nothing is
   called before the answer.
2. **Given** the person presses **Don't**, or does not answer in 2 minutes, **Then** nothing is
   called and the agent is told "The person said no."
3. **Given** the person presses **Start It** (or **Stop It**), **Then** the control plane calls
   the draft's start (or stop) once, with the contract's timeouts, and gives the agent the
   result.
4. **Given** a workspace is linked to a host that has agents working, **Then** the agent can't
   ask to stop it. The tool says "Agents are working on ‹host›."
5. **Given** the agent started a workspace and the sheet closes, **Then** the workspace is left
   as it is. The sheet said so with the yes: "It stays running until you stop it."

---

### User Story 4 - Write a new map for a provider that changed (Priority: P3)

A server's new version renames a tool. The provider card says "Couldn't list: The tool map names
droplet-list, which the server doesn't have." The card's **Edit…** sheet has Write It for Me,
which starts from the old map.

**Why this priority**: it reuses everything above. It is rare, but the alternative is to remove
and add the provider again.

**Independent Test**: change the test server's tool names, open Edit…, press Write It for Me.
See the agent get the old map, and **Save** keep the new one.

**Acceptance Scenarios**:

1. **Given** Edit… on a mapped or commands provider, **When** Alex presses Write It for Me,
   **Then** the agent gets the old map or config, and the last list's problem, as well.
2. **Given** a new draft, **When** Alex presses Save, **Then** it is saved as
   `providers/update` saves it today. The provider's hosts stay linked.

---

### Edge Cases

- **No host on the control plane's machine** (a control plane in the cloud with no host
  beside it): Write It for Me is off, with "No host runs where the control plane runs, so no
  agent can write here."
- **The default runtime can't run with its own tools off** (FR-010): it is not in the menu. If
  no runtime can, Write It for Me is off, with the reason.
- **The agent finds no tool that lists machines**: it ends with a sentence. The sheet shows it
  ("It has no tool that lists machines.") and leaves the field empty.
- **The agent runs out of time** (FR-017): the sheet shows "Couldn't write a map in 5 minutes."
  with **Try Again**. The last draft that passed its check, if any, is in the field.
- **The check fails every time**: after 8 checks the agent is told to stop. The sheet shows the
  last draft and its failure, so the person can fix it by hand.
- **× or Back or Cancel while it writes**: the agent stops. Its draft is dropped. Nothing is
  saved.
- **The person types in the field while the agent writes**: the field is read-only while the
  agent writes. **×** gives it back.
- **A secret's value is in the server's output** (an error that echoes the token): it is
  replaced with `${NAME}` before the agent sees it, in every tool result.
- **A secret is short** (under 6 characters): it is still replaced, but only as a whole word,
  so that common text is not broken.
- **The list tool the agent names looks like it changes something** (FR-013): the check is not
  called. The sheet asks the person first, as in US3.
- **The server needs a sign-in** (OAuth): as #691, "It wants a sign-in, which providers can't do
  yet: give it a token as a secret." No agent starts.
- **The control plane restarts while the agent writes**: the draft is lost. The sheet shows
  "The control plane restarted." with Try Again.
- **Two sheets at once** (two Macs): each has its own draft and its own agent.
- **The agent's turn costs money**: the step line shows its cost when the runtime reports one.

## Requirements *(mandatory)*

### Functional Requirements

**The sheet (Mac only)**

- **FR-001**: The MCP server form and the Your commands form MUST have **Write It for Me** and a
  runtime menu, as layouts L10 draws them. Other kinds (the presets) MUST NOT have them.
- **FR-002**: The Your commands form MUST have a **CLI** field, the program the commands use.
  Write It for Me MUST be off until it, or the server's command or address, is filled in.
- **FR-003**: While the agent writes, the sheet MUST show one step line: a spinner, the latest
  step in a few words, the turn's cost when known, and **×**. **Details** MUST show every step
  and the agent's last words.
- **FR-004**: When the agent ends, its draft MUST fill the form's fields (the Tool map editor,
  or the Your commands fields, or a Config editor for a config the fields can't hold). The
  sheet MUST show the last check's list line, and "Written by ‹runtime›. Read it before you
  add it."
- **FR-005**: **Add** (or **Save** in Edit…) MUST do what it does today, with no agent: connect,
  check and list, then keep. The draft is not kept before Add.
- **FR-006**: A refusal at Add that a map would fix (no contract tools; a map tool missing) MUST
  have **Write a Tool Map**.

**The writing agent**

- **FR-007**: The agent MUST run on the host on the control plane's machine, with the runtime
  chosen in the menu. The menu MUST default to that host's default runtime.
- **FR-008**: The agent MUST run in a scratch folder in the control plane's home, with no
  project. The folder MUST be deleted when the draft ends.
- **FR-009**: The agent's session MUST NOT show in any client's sidebar. Its transcript MUST be
  kept for 7 days, and **Details** MUST open it, read-only.
- **FR-010**: The agent MUST have only the writer's tools (contracts/writer-tools.md), and
  `show_file` off. Its runtime's shell, file write, web and subagent tools MUST be off. A
  runtime that can't turn them off (#015, #064) MUST NOT be offered.
- **FR-011**: The writer's tools MUST answer only the agent started for that draft, by its
  token. Any other agent's call MUST be refused.

**What the control plane runs for it**

- **FR-012**: The control plane MUST connect to the server, read `tools/list` (names,
  descriptions, input schemas and annotations), run help, check drafts, and call start or stop.
  The agent MUST NOT reach the server or the CLI any other way.
- **FR-013**: The check of a tool map MUST call its `list.tool` only if that tool is not named
  by the draft's `start`, `stop`, `create` or `delete`, does not have `destructiveHint: true`
  or `readOnlyHint: false`, and its name has none of the words create, delete, destroy, remove,
  power, start, stop, reboot, resize, update or set. Otherwise the sheet MUST ask the person
  first, as FR-019 asks.
- **FR-014**: The control plane MUST run a CLI on the agent's word only as `‹cli› ‹words…›
  --help` (help), or as the draft's `list` or `status` (a check). A check command MUST start
  with the CLI and have none of `;`, `&`, `|`, `>`, `<`, `` ` ``, `$(` or a newline, and its
  words must not include delete, rm, destroy, create, start or stop. Otherwise the sheet MUST
  show it with **Run Check**, for the person.
- **FR-015**: Help and checks MUST use the command provider's timeouts for `list` (25 s). Each
  output MUST be cut at 16 KB for the agent, with a line that says it was cut.
- **FR-016**: A check MUST be the same code as the check at Add (#691 `ProviderConnection.check`),
  run on the draft. It MUST NOT keep anything.
- **FR-017**: A draft MUST end after 5 minutes, or 8 checks, or 40 tool calls, whichever comes
  first. The agent MUST be told why it ended.

**Start and stop on asking**

- **FR-018**: The agent MAY ask for one start or one stop of one workspace from the last list.
  The control plane MUST NOT call it without the person's yes, each time.
- **FR-019**: The question MUST be in the sheet. It MUST name the workspace and the provider,
  give the cost when the list gave one, and say "It stays running until you stop it" for a
  start. No answer in 2 minutes MUST be a no.
- **FR-020**: A stop of a workspace whose host has turns running MUST be refused (as #691 US4).

**Secrets**

- **FR-021**: The secrets typed in the sheet MUST go to the control plane with the draft
  request. The control plane MUST hold them only in memory for the draft, and MUST pass them
  only to the server or the CLI, as #691 does.
- **FR-022**: Every text the agent gets MUST have each secret's value replaced with `${NAME}`.
  The agent MUST be told the secrets' names, never their values.
- **FR-023**: The draft MAY use `${NAME}` where the map or config takes text. The check MUST
  fill it in as #691 does.
- **FR-024**: Nothing the agent writes, and no log line, MUST hold a secret's value. A test MUST
  scan the transcript, the log and the draft for each value.

**Run time**

- **FR-025**: Start, Stop, list, Start when used and Stop when idle MUST NOT start an agent or
  call a model. They MUST use only the kept map or config.

**Clients**

- **FR-026**: The Remote and the web page MUST NOT change (#691 L7): `remote: by design`,
  `web: by design`. The parity table's row for Workspace providers MUST name Write It for Me.

### Key Entities

- **Draft**: one Write It for Me, held by the control plane in memory: its id, the form so far,
  the secrets, the runtime, the agent's session, its steps, the last draft and its check, and
  its state (writing, asking, done, failed, cancelled). It ends with the sheet.
- **Step**: one thing the draft did, in a few words, for the step line and Details: "read 41
  tools", "ran cws list --help", "checked: listed 3", "check failed: …", "asked to start
  scratch-1".
- **Authorship**: a field on the provider record, `writtenBy: {runtime, at}`, set when Add keeps
  a draft that an agent wrote and the person did not change. A changed draft is the person's.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For DigitalOcean's MCP server, Write It for Me gives a map that passes its check
  in under 2 minutes, in 4 of 5 tries, with the default runtime.
- **SC-002**: For a fake CLI with `list`, `start`, `stop` and help (the test fixture), it gives a
  config that passes in under 2 minutes, in 4 of 5 tries.
- **SC-003**: No secret's value is in any transcript, log line or draft, in every test (FR-024).
- **SC-004**: No start or stop is called during authoring without a yes, in every test.
- **SC-005**: A Start or Stop of a provider with an agent-written map calls no model: the same
  call count and time as a hand-written map.
- **SC-006**: Add Provider with a server that follows the contract, or a preset, works as fast
  as it does today: Write It for Me adds no step to it.

## Docs *(mandatory)*

- `docs/how-to/add-a-workspace-provider.md`: change. Write It for Me for a server and for a
  CLI; what the agent sees and does not see; start and stop on asking.
- `docs/reference/workspace-providers.md`: change. A line under the tool map: an agent can write
  it at Add Provider; the map is then the same as a hand-written one.
- `docs/explanation/control-plane.md`: change. The writing agent runs on the control plane's
  host, at authoring only; secrets stay with the control plane.
- `docs/reference/agent-tools.md`: change. The writer's tools, as the writing agent alone has
  them.

## Assumptions

- #691 US1 and US2 are merged (they are, 2026-10-12). The sheet, `ProviderConnection.check`,
  `ProviderSecrets` and the command provider are as they are on main.
- The control plane can start an agent on the host on its own machine as a client does
  (`agents/start`), and that host relays the agent's tools to it as #691 US6 does
  (`host/workspaces`).
- Runtimes can be started with their own tools off through the per-runtime controls of #015
  and #064. Claude, Codex and Grok can. Others are checked in the plan's research.
- The agent writes the same map format as a person. No new format.
- A draft is short and in memory. It does not survive a control plane restart.
