# Feature Specification: Workspace providers through MCP

**Feature Branch**: `agents/spec-691-workspace-providers`

**Created**: 2026-10-11

**Status**: Draft

**Input**: Issue #691, "Start and create remote workspaces through MCP workspace providers".

## Why this feature exists

Agents can join a remote workspace as a host (Add a Server, with an ssh tunnel when the
workspace can't dial back), but it can't start one. When a cloud workspace stops (it idles out,
or someone turns it off to save money), its host is shown offline and every request for it is
refused with "That host is offline." Someone then has to open the provider's console or
Terminal, start the workspace by hand, and wait.

There are many providers: DigitalOcean droplets, GitHub Codespaces, Coder, Google Cloud
Workstations, company-internal ones (CWS), and a Docker container on this Mac. Agents should not
have code for each. Following #383 ("one MCP server is a whole integration"), a **workspace
provider is an MCP server** offering a small, fixed set of tools. Anyone can write one for any
provider, share it as a plugin or through the marketplace, and Agents knows how to use all of
them the same way. Because they are ordinary MCP tools, agents can use them too, so an agent can
later start a workspace for a branch, or make a new one.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a stopped workspace (Priority: P1)

Alex has added a provider to the control plane (Settings ▸ Control plane ▸ Providers) and linked
the `devbox` host to one of its workspaces. The workspace is stopped. On the offline strip of a
devbox chat, and on devbox's row under Hosts, there is a **Start** button. Alex presses it. The
strip says **Starting devbox…**, then **Waiting for devbox to connect…**, and then the host
comes online and the strip goes away.

**Why this priority**: this is the gap. Everything else builds on the control plane being able
to start a workspace through a provider.

**Independent Test**: with a stand-in provider whose workspace's "start" launches the Linux
devbox container (or a fake host), stop the container, press Start, and see the host come
online without touching Terminal.

**Acceptance Scenarios**:

1. **Given** a host linked to a stopped workspace, **When** Alex presses **Start** on the Mac,
   the Remote or the web page, **Then** the control plane asks the provider to start it, and
   every client shows the host as **starting** until it connects.
2. **Given** the provider says the workspace has started, **When** the host's agentsd does not
   connect within 2 minutes, **Then** the control plane runs agentsd over ssh, as an install
   does, and keeps waiting. A host reached through a tunnel gets its tunnel opened at once.
3. **Given** the start fails (the provider errors, the workspace is gone, or the host never
   connects within 10 minutes), **When** the attempt ends, **Then** the strip and the Hosts row
   say why, in the provider's words, and offer **Start** again.
4. **Given** a host is starting, **When** someone presses **Start** again on any client,
   **Then** nothing more happens: one start is in flight per workspace.
5. **Given** a host that is not linked to a workspace, **When** it is offline, **Then** there
   is no **Start** button, as today.

---

### User Story 2 - Add a provider and link workspaces (Priority: P1)

Alex opens Settings ▸ Control plane ▸ Providers and adds one: an MCP server, either a command
the control plane runs (stdio) or an address (http), with any secrets it needs (an API token).
The control plane checks that the server is a workspace provider and lists its workspaces.
Each workspace shows its state and whether it is already a host. Alex links a workspace to an
existing host, or adds it as a new host, which runs the usual install over the ssh destination
the provider gives.

**Why this priority**: without a way to add a provider, there is nothing to start.

**Independent Test**: add the stand-in provider, see its two workspaces listed with their
states, link one to `devbox`, and add the other as a new host.

**Acceptance Scenarios**:

1. **Given** an MCP server that offers the workspace tools, **When** Alex adds it, **Then** it
   is listed under Providers with its name and its workspaces.
2. **Given** an MCP server that does not offer them, **When** Alex adds it, **Then** it is
   refused, naming the tools it lacks.
3. **Given** a workspace that is running and not yet a host, **When** Alex chooses **Add as
   Host**, **Then** the Add a Server flow starts with the provider's ssh destination and its
   tunnel suggestion filled in, and ends with the host linked to the workspace.
4. **Given** an existing host, **When** Alex chooses **Link to Workspace…** on its row,
   **Then** a list of the providers' unlinked workspaces is offered, and the chosen one is
   linked.
5. **Given** a provider is removed, **When** its hosts are next shown, **Then** they stay as
   hosts, unlinked, and lose their **Start** buttons.
6. **Given** a provider's secret, **When** anything is shown or logged, **Then** the secret is
   never shown again after it is entered, never sent to a host or a client, and never written
   to the log.

---

### User Story 3 - Start a workspace by using it (Priority: P2)

Alex, on the iPhone, sends a prompt to an agent on devbox, which is stopped. Today that is
refused. Now the prompt is kept, devbox is started, and the prompt is delivered when devbox
connects. The chat shows the prompt as waiting for devbox, with a way to cancel it. Starting a
new agent in a project on devbox works the same way.

**Why this priority**: it makes a stopped workspace feel like a running one. Pressing Start is
enough to be useful; this makes it effortless.

**Independent Test**: stop the stand-in workspace, send a prompt from the web page, close the
page, and see the agent answer it once the workspace is up.

**Acceptance Scenarios**:

1. **Given** a host linked to a stopped workspace with **Start when used** on (the default),
   **When** a client sends a prompt to one of its agents or starts an agent in one of its
   projects, **Then** the control plane keeps the request, starts the workspace, and delivers
   the request once when the host connects.
2. **Given** a kept prompt, **When** the sender closes the app, **Then** the prompt is still
   delivered: it is kept by the control plane, not the client.
3. **Given** a kept prompt, **When** anyone presses × on it, **Then** it is dropped and not
   delivered. The workspace keeps starting.
4. **Given** the start fails, **When** the attempt ends, **Then** each kept request is shown as
   not sent, with the reason and a **Try Again**, as a failed send is shown today.
5. **Given** **Start when used** is off for the host, **When** a request arrives while it is
   stopped, **Then** it is refused as today, and the strip offers **Start**.
6. **Given** a read (a file, a transcript page) for a stopped host, **When** it arrives,
   **Then** it does not start the workspace. Only sending a prompt and starting an agent do.

---

### User Story 4 - Stop a workspace when idle (Priority: P2)

A linked host can be set to stop its workspace after it has been idle for a while (default
30 minutes, on for new links). Idle means no turns running, no agents waiting on a question,
and no terminal or shell open, all for the whole period. The control plane then asks the
provider to stop it. Alex can also press **Stop** on its row.

**Why this priority**: workspaces cost money while they run. Starting on demand only pays off
if they also stop by themselves.

**Independent Test**: set the stand-in host's idle time to 1 minute, finish a turn, and see the
workspace stopped about a minute later, its host shown as **stopped** (not offline).

**Acceptance Scenarios**:

1. **Given** a host idle for its set time, **When** the time passes, **Then** the control plane
   stops the workspace, and the host is shown as **stopped by Agents after N minutes idle**.
2. **Given** a turn starts during the idle period, **When** the time would have passed,
   **Then** nothing is stopped, and the period starts again when the host is next idle.
3. **Given** a host with scheduled workflows, **When** its idle stop is on, **Then** its row
   warns that scheduled workflows on it don't run while it is stopped.
4. **Given** Alex presses **Stop** while a turn is running, **When** asked, **Then** a
   confirmation names the running agents, and stops only if Alex confirms.

---

### User Story 5 - Make a new workspace (Priority: P3)

For a provider that can create workspaces, Settings ▸ Control plane ▸ Providers has **New
Workspace…**. Its form is drawn from the provider's options (region, size, image). Before
anything is made, a confirmation says what will be made and, when the provider says, what it
costs. Once made, the workspace joins as a host by itself and is linked. **Delete Workspace…**
on a linked host removes both, after a confirmation that names what is lost.

**Why this priority**: a person can make workspaces in the provider's own console and link
them (Story 2). Making them here is a convenience, and the first step toward agents doing it.

**Independent Test**: with the stand-in provider, make a workspace and see it join as a host
with no ssh step; delete it and see both the workspace and the host gone.

**Acceptance Scenarios**:

1. **Given** a provider that offers `workspace_create`, **When** Alex fills in New Workspace
   and confirms, **Then** the control plane passes the provider a one-time install command
   with a host code, the provider runs it on the new workspace's first boot, and the host
   joins and is linked without ssh.
2. **Given** a provider that cannot run a command on first boot, **When** the workspace is
   made, **Then** the control plane installs over the ssh destination it returns, as in Story 2.
3. **Given** Alex has not confirmed, **When** the form is cancelled, **Then** nothing is made.
4. **Given** a linked host, **When** Alex confirms **Delete Workspace…**, **Then** the provider
   deletes the workspace and the host is removed, as **Remove** does today.

---

### User Story 6 - Agents use workspaces (Priority: P3)

Agents get the app's own tools for workspaces: list workspaces and their hosts, start one, stop
one, and make one. An agent can start devbox before starting a helper there, or make a
workspace for a long branch build. Making and deleting always ask Alex first, through the app's
usual question card; listing, starting and stopping follow the agent's permission mode.

**Why this priority**: it is where Alex wants this to go, and it needs the rest first.

**Independent Test**: ask an agent to start devbox and then start a helper in a project on it;
see devbox start and the helper run there. Ask it to make a workspace and see the question card
before anything is made.

**Acceptance Scenarios**:

1. **Given** an agent, **When** it lists workspaces, **Then** it sees each provider's
   workspaces, their states and the hosts they are linked to, and never a provider's secrets.
2. **Given** an agent asks to make or delete a workspace, **When** the tool is called,
   **Then** Alex is asked first, on every client, and nothing happens until Alex allows it.
3. **Given** an agent starts a workspace, **When** it is up, **Then** the agent can be told so
   by waiting for the existing `server.online` event.

### Edge Cases

- **The control plane is on a Mac that sleeps**: nothing can start a workspace while it sleeps,
  as nothing can reach a host now. A control plane in the cloud (#61) can start workspaces with
  the Mac asleep, which is the main reason providers run on the control plane.
- **A stdio provider on a cloud control plane**: it runs inside the control plane's container,
  so the provider's command (and any CLI it uses, such as `doctl`) has to be there. An http
  provider needs nothing installed. The Providers page says which kind each is.
- **Several copies of the control plane** (a mesh): one copy at a time runs each provider and
  holds the starts, stops and idle timers for its workspaces, as one copy holds tunnels today.
- **A workspace started outside Agents**: its host connects as usual; the control plane notices
  through the provider's list and shows it running.
- **A workspace stopped outside Agents**: its host goes offline as now; the next list shows it
  **stopped**, and the strip offers **Start** instead of a reconnect countdown.
- **The workspace's agentsd doesn't start on boot** (a Linux user service without lingering):
  covered by Story 1's ssh start after 2 minutes. Without an ssh destination, the strip says
  agentsd didn't start and how to make it start on boot.
- **The provider is unreachable**: its workspaces show their last known state, marked as not
  current; Start, Stop and idle stops fail with the reason and are retried only by a person or
  the next request.
- **The provider changes a workspace's ssh destination** (a new IP after a restart): the
  control plane uses the newest one for its ssh start and tunnel.
- **Two hosts linked to one workspace**: not allowed; linking moves the link.
- **A kept request for a host that is then removed**: it is dropped and shown as not sent.
- **Many kept prompts**: at most 20 per host; more are refused with "devbox is starting; too
  many prompts are waiting".
- **Hosts never escalate**: nothing here asks for admin or root, on the control plane, the
  host or the provider's side.

## Requirements *(mandatory)*

### Functional Requirements

**The provider contract**

- **FR-001**: A workspace provider MUST be an MCP server offering at least `workspaces_list`,
  `workspace_start` and `workspace_stop`. It MAY offer `workspace_options`, `workspace_create`
  and `workspace_delete`. The contract is published in this repo, versioned, and checked when a
  provider is added.

  | Tool | Takes | Returns |
  | --- | --- | --- |
  | `workspaces_list` | nothing | The contract version, and each workspace: a stable id, a name, a state (`running`, `starting`, `stopping`, `stopped`, `unknown`), its ssh destination when it has one, whether it needs a tunnel, and optionally a cost note. |
  | `workspace_start` | an id | Once the provider reports it running, or failed with a reason. |
  | `workspace_stop` | an id | Once the provider reports it stopped, or failed with a reason. |
  | `workspace_options` | nothing | The choices for a new workspace, as a schema the form is drawn from. |
  | `workspace_create` | a name, chosen options, and optionally a command to run on first boot | The new workspace, as in `workspaces_list`, and whether the command will run. |
  | `workspace_delete` | an id | Once it is gone, or failed with a reason. |

- **FR-002**: Providers MUST be configured on the control plane, not on a host, so that they
  can start a workspace whose host is down. A provider is stdio (a command) or http (an
  address), with named secrets.
- **FR-003**: Provider secrets MUST be kept where the control plane keeps its own secrets, MUST
  NOT be returned to any client or agent, and MUST NOT be logged.
- **FR-004**: The control plane MUST read each provider's list when it starts, every 5 minutes,
  after every start, stop, create or delete, and when the Providers page or a Hosts page is
  opened.
- **FR-005**: A provider call MUST time out after 10 minutes for start, stop, create and delete,
  and 30 seconds for list and options. A timeout is shown as a failure with that reason.

**Links and states**

- **FR-010**: A host MAY be linked to one workspace of one provider. The link is kept in the
  control plane's store and survives restarts.
- **FR-011**: A linked host's state MUST add **stopped**, **starting** and **stopping** to the
  existing ones, drawn on the Mac, the Remote and the web page wherever host state is drawn
  today (the Hosts rows, the offline strip, project headings).
- **FR-012**: **Start** and **Stop** MUST be offered for a linked host, on all three clients,
  on its Hosts row (Mac) and its offline strip (all three). One start or stop at a time per
  workspace.
- **FR-013**: After a successful start, if the host has not connected within 2 minutes and the
  provider gave an ssh destination, the control plane MUST start agentsd over ssh with the
  host's existing record, and open its tunnel if it has one. It MUST NOT reinstall.

**Start when used**

- **FR-020**: With **Start when used** on (default on for a linked host), a prompt to an agent
  on the stopped host, or a request to start an agent there, MUST be kept by the control plane,
  start the workspace, and be delivered once, in order, when the host connects.
- **FR-021**: Kept requests MUST survive a restart of the control plane, be shown in the chat
  as waiting for the host on all three clients, and be cancellable by any client.
- **FR-022**: No other request MAY start a workspace. Other requests for a stopped host are
  refused as today, with the refusal saying it is stopped and can be started.

**Stop when idle**

- **FR-030**: A host MUST report to the control plane whether it is idle: no turns in flight,
  no agent waiting on a question, and no terminal or project shell open.
- **FR-031**: With **Stop when idle** on (default on, 30 minutes, for a new link), the control
  plane MUST stop the workspace once the host has been idle for the whole period, and record
  that it did and why.

**Creating and deleting**

- **FR-040**: **New Workspace…** MUST be offered only for providers with `workspace_create`,
  draw its form from `workspace_options`, and confirm before calling it.
- **FR-041**: The control plane MUST pass `workspace_create` a one-time install command with a
  host code, as `install.sh` takes today, so the workspace joins by itself and is linked. If the
  provider can't run it, the control plane MUST install over ssh as in Story 2.
- **FR-042**: **Delete Workspace…** MUST confirm, call `workspace_delete`, and on success remove
  the host as **Remove** does.

**Agents**

- **FR-050**: The app's tools for agents MUST include listing workspaces, starting, stopping,
  creating and deleting them, all through the control plane, never the provider directly.
- **FR-051**: Creating and deleting from an agent MUST ask Alex first through the app's
  question card. Nothing is made or deleted without that answer.

**Records**

- **FR-060**: Every start, stop, create and delete, who or what asked for it (a client, an
  agent, a kept prompt, an idle timer), and its result MUST be in the control plane's log.

**The bundled and reference providers**

- **FR-070**: Agents MUST ship a **command provider**: a small MCP provider whose workspaces
  are each a name with a start command, a stop command, an optional status command and an ssh
  destination (`cws start devstack-1`, `docker start agents-devbox`). It is how a single
  workspace is set up with no provider of its own, and it goes through the same path as any
  other provider.
- **FR-071**: The repo MUST hold a **DigitalOcean provider** (droplets: list, power on, power
  off, create from options, delete) as the reference for people writing their own.

### Key Entities

- **Provider**: an MCP server configured on the control plane, stdio or http, with its secrets
  and the contract version it offers.
- **Workspace**: a provider's id, name, state, ssh destination, tunnel hint and cost note, as
  last listed, and when.
- **Link**: a host and the workspace it runs on, with its **Start when used** and **Stop when
  idle** settings.
- **Kept request**: a prompt or agent start for a stopped host, held by the control plane until
  it connects, is cancelled or the start fails.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A stopped workspace is running and its host connected within the provider's own
  start time plus 1 minute of pressing **Start**, with nothing done outside Agents.
- **SC-002**: A prompt sent to a stopped workspace from the phone is answered with no other
  action by Alex, in 10 out of 10 tries, including with the phone locked right after sending.
- **SC-003**: Across a week, no linked workspace with **Stop when idle** on runs more than its
  idle time plus 5 minutes past its last activity.
- **SC-004**: A new provider can be written for any service with a CLI or an API in under 200
  lines, using only the published contract and the reference provider as a guide, and works
  with no change to Agents.
- **SC-005**: No provider secret appears in any client, agent transcript or log.

## Docs *(mandatory)*

- `docs/how-to/start-workspaces-from-agents.md`: add. Add a provider, link a host, Start, Start
  when used, Stop when idle, with the command provider as the first example.
- `docs/reference/workspace-providers.md`: add. The contract: tools, arguments, results, states,
  versions, and how the first-boot install command works.
- `docs/how-to/write-a-workspace-provider.md`: add. Walk through the DigitalOcean provider.
- `docs/how-to/add-a-server.md`: change. Mention adding a server from a provider's workspace.
- `docs/explanation/control-plane.md`: change. Providers run on the control plane; kept
  requests; the new host states.
- `docs/reference/agent-tools.md`: change.
  The workspace tools and which ones ask first.

## Parity

- **Start, Stop, the new host states, and kept prompts**: **mac: same, remote: same, web:
  same**. They are on the offline strip and in the chat, which all three draw.
- **Settings ▸ Control plane ▸ Providers, Link to Workspace, New and Delete Workspace**: **mac
  only, remote: by design, web: by design**, as Settings ▸ Control plane (Hosts) is Mac only
  today. If Hosts settings come to the other two, Providers comes with them.
- `specs/071-web-remote/walks/parity.md` gains rows for both.

## Assumptions

- The contract is our own convention on top of ordinary MCP tools. Recognising a provider by
  its tool names and the version in `workspaces_list` is enough; no MCP extension is needed.
- The control plane gets an MCP client of its own, for providers only. It is separate from the
  daemon's, which keeps serving agents and #383 event triggers.
- Providers MAY also offer #383 events (`workspace.stopped`) for workflows, through a host's own
  MCP config. The control plane itself reads the list, and does not need events.
- Walks use a stand-in provider and the Linux devbox container. The DigitalOcean provider is
  tested against a stand-in API; trying it on a real account needs Alex's token, and Claude
  never creates a droplet or account itself.
- Kept requests are only prompts and agent starts. Other work that needs a running host
  (scheduled workflows, event triggers on that host) doesn't start a workspace in this feature.
- A provider configured only in a host's own `~/.agents/mcp.json` gives that host's agents its
  tools as any MCP server does, but the control plane doesn't use it to start workspaces. Only
  providers configured on the control plane do.
