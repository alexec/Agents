# Feature Specification: Agent configuration sync

**Feature Branch**: `agents/issue-2129-config-sync`

**Created**: 2026-10-23

**Status**: Draft (machine-to-machine sync withdrawn 2026-10-27, FR-001)

**Input**: GitHub issue #2129: agent configuration syncs both ways across the user's machines and workspaces, with the newest file winning.

## Why this feature exists

People use the same agent instructions, personas, skills, MCP server list and plugins on
more than one machine. Today, each machine can have a different copy. A person must copy
files by hand, and a workspace can start before it has the configuration its agents need.

The control plane already knows which machines belong to a person. It can carry each
configuration file to those machines and keep a copy for a machine that is offline.

## User scenarios and testing

### User Story 1 - Local edits sync to every machine (Priority: P1)

Alex edits an agent instruction on the Mac, or edits a skill on a workspace. The change
reaches the control plane and every other machine. The edit does not need a button press.

**Why this priority**: This is the core behavior. It removes manual copying and keeps
agents consistent.

**Independent Test**: Change one file on one connected machine. Check that the control
plane and each other connected machine have the same bytes. Repeat with an edit made by
hand on disk.

**Acceptance Scenarios**:

1. **Given** two connected machines for one person, **When** a file in the sync scope is
   added or edited on either machine, **Then** the control plane and the other machine
   receive its newest contents without a user action.
2. **Given** the control plane sends a file to a machine, **When** the local file watcher
   observes the write, **Then** it does not send that write back as a new edit.
3. **Given** an edit arrives while another edit to the same file is pending, **When** the
   control plane compares them, **Then** it keeps the later edit according to the shared
   logical time and machine ID tie-break.

### User Story 2 - Offline and new machines get the current files (Priority: P1)

A machine that is offline receives the latest configuration when it reconnects. A new
workspace receives it before its first agent starts.

**Why this priority**: New and temporary workspaces are where missing configuration
causes the most confusion.

**Independent Test**: Edit a file while one machine is offline, then reconnect it. Start
a new workspace and verify that its first agent sees the current configuration.

**Acceptance Scenarios**:

1. **Given** a machine is offline during several edits, **When** it reconnects, **Then**
   it receives the newest state for each path, including deletions.
2. **Given** a workspace joins as one of the person's machines, **When** its first agent
   can run, **Then** its initial configuration sync has completed.
3. **Given** no control plane is paired, **When** a person edits configuration, **Then**
   the local files continue to work and no cross-machine sync is attempted.

### User Story 3 - Configuration is the same in all three clients (Priority: P1)

The Mac, Remote and web pages show that agent configuration syncs to all the person's
machines and show when the last sync completed. Agent configuration has no per-machine
switch. Other settings follow their fixed scopes (#2410); they have no scope controls.

**Why this priority**: People need clear feedback about the state and scope of their
configuration.

**Independent Test**: Open Agent Configuration on each client and verify that the same
scope and sync time are shown, with no switch to turn configuration sync off.

**Acceptance Scenarios**:

1. **Given** the person opens Agent Configuration on any client, **When** configuration
   sync is active, **Then** the page says "The same on all your machines" and shows the
   last successful sync.
2. **Given** the person opens settings for runtimes, cost limits or resources, **When**
   they view runtime choices, cost limits or resources, **Then** the fixed scope is clear
   and there is no control to change it.
3. **Given** the person makes an agent configuration change in a client, **When** it is
   saved, **Then** the other clients show the resulting sync state.

## Edge cases

- Two machines edit the same path while offline. The edit with the later logical time
  wins; the machine ID breaks an exact tie.
- A file is deleted while a machine is offline. A deletion record prevents the old file
  from returning when that machine reconnects.
- A path changes from a file to a directory, or the reverse. The current winning state
  for that path and its children is applied without leaving stale files.
- A file is too large, unreadable or outside the allowed configuration paths. It is
  skipped safely, and the sync state reports the error without exposing file contents.
- Dependency and cache folders, including `node_modules`, are not synced.
- MCP secrets stay sealed. The control plane does not receive plaintext secret values.
- A machine has not completed its initial sync. It must not start its first agent yet.
- The control plane is unavailable. Local configuration remains usable; pending local
  edits sync when the machine reconnects.

## Requirements

### Functional requirements

- **FR-001**: A machine MUST NOT send its agent configuration files (`AGENTS.md`,
  personas, skills, the MCP server list or plugins), or their removal, to the person's
  other machines, and MUST NOT write or remove the ones a control plane sends. Only the
  person's own clients (the Mac window, the Remote and the web page) change what follows
  the person, with `user/setSettings`. The control plane refuses
  `user/setAgentConfigFile`, so one machine cannot change what runs on the others.
  FR-002 to FR-010 and FR-015, the machine-to-machine sync, are withdrawn by this rule
  (2026-10-27).
- **FR-002**: The system MUST detect edits made in Settings and edits made directly to
  files on disk.
- **FR-003**: The system MUST sync each file independently between each machine and the
  control plane.
- **FR-004**: The system MUST keep the edit with the newest logical time for each path.
  It MUST use the machine ID to resolve equal times.
- **FR-005**: The system MUST keep deletion records until all machines can receive the
  deletion or the record is safely superseded.
- **FR-006**: The system MUST apply remote writes atomically and MUST NOT echo them as
  new local edits.
- **FR-007**: The system MUST send the newest state to offline machines when they
  reconnect.
- **FR-008**: The system MUST complete initial sync before a new or started workspace
  can run its first agent.
- **FR-009**: The system MUST not sync when there is no control plane. Local configuration
  MUST remain usable in that state.
- **FR-010**: The system MUST exclude dependency and cache folders, including
  `node_modules`, from plugin sync.
- **FR-011**: The system MUST keep MCP secrets sealed so the control plane cannot read
  them.
- **FR-012**: The Agent Configuration page MUST state that configuration syncs to all
  the person's machines and show the latest successful sync on Mac, Remote and web.
- **FR-013**: The system MUST remove the Agent Configuration and MCP servers rows from
  the former per-part machine-scope settings. Runtime choices and cost limits have fixed
  person scope; resources have fixed machine scope (#2410).
- **FR-014**: The system MUST report sync progress and errors without displaying secret
  values or configuration contents.
- **FR-015**: The system MUST reject a file over 1 MiB and MUST keep no more than 4,096
  configuration paths or 64 MiB of active configuration for one person.

### Key entities

- **Configuration file**: A relative path, file contents, content digest, logical edit
  time and machine ID.
- **Deletion record**: A relative path and logical edit time that marks the file as
  deleted.
- **Machine sync state**: A machine's last applied logical time and current sync status.
- **Plugin file**: A regular file inside a configured plugin, excluding dependency and
  cache folders.

## Success criteria

- **SC-001**: A connected machine receives a file edit on every other connected machine
  within 10 seconds under normal network conditions.
- **SC-002**: A reconnected machine reaches the current per-file state before its next
  agent starts.
- **SC-003**: After competing offline edits, all machines converge to the same contents
  for each path without a conflict copy or user prompt.
- **SC-004**: The Mac, Remote and web pages show the same sync scope and last-successful
  sync state.
- **SC-005**: No plaintext MCP secret is present in control-plane storage or logs.
- **SC-006**: Local configuration remains usable when the control plane is unavailable.

## Docs

- `docs/reference/settings.md` — explain automatic agent configuration sync and the files
  it includes.
- `docs/how-to/back-up-and-restore.md` — clarify that synced configuration is available
  on a person's machines but is not a backup.

## Assumptions and decisions

- The control plane is required for cross-machine sync. With no control plane, a machine
  uses its local files and sync resumes after reconnection.
- Agent configuration always syncs. Runtime choices, cost limits and resources keep the
  switches from #1760.
- Plugin dependency and cache folders are excluded. This includes `node_modules`.
- A configuration file is at most 1 MiB. One person can keep at most 4,096 paths and
  64 MiB of active file contents.
- Concurrent edits use the newest logical time, with machine ID as a stable tie-break.
- MCP secret values keep the sealed design from #1924 and do not become readable to the
  control plane.
