# Feature Specification: Cloud Agents

**Feature Branch**: `037-cloud-agents`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Cloud agents, i.e. connect to a server via SSH and work there rather than locally. Something like SCPing the agentd to the remote machine and then connecting via a local socket forward."

## Why this feature exists

Every agent today runs on the Mac. That ties the work to the Mac: when the lid closes, the agents
stop; when the laptop is on hotel Wi-Fi, their builds crawl; when the code needs Linux, a GPU, a big
disk, or a network the Mac is not on, the agent cannot get there. And four agents building at once
make the laptop loud and slow for the person trying to use it.

The person usually already has somewhere better for the work to happen: a Linux box under a desk, a
cloud VM, a dev server at work. They reach it with SSH. What they do not have is a way to point this
app at it. So they either give up the app for a terminal on the server, or they keep the work on the
Mac where it does not belong.

The app is already split in two. The window is a client; the daemon does the work, and the window
only ever asks it. So the daemon can live somewhere else. Put it on the server over SSH, reach it
through the SSH connection, and a project on that server looks and behaves like any other project —
except that its agents keep working after the laptop goes to sleep.

**This feature does not change what a project or an agent is.** A project on a server is an ordinary
project whose folder is on another machine. Once it is added, the window treats it the same as a
local one: the same agent list, chat, files pane, terminal, worktrees and costs.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Add a server and start an agent there (Priority: P1)

The person has a Linux server they can already `ssh` into. In the app they add it by the name they
use with SSH — an alias from their SSH config, or `user@host`. The app connects, sets itself up on
the server without them doing anything there, and says the server is ready. They make a project on
it — choosing a folder on the server, or giving a Git URL to clone there — and start an agent. The
agent works on the server: its commands run there, its edits land there, and the files pane and
terminal show the server's folder.

**Why this priority**: It is the whole of the request. Without it nothing else in this spec exists.

**Independent Test**: With a Linux server reachable by key-based SSH, that has never run this app
and has an agent CLI installed and logged in, add it in the app, create a project on it from a
folder that exists there, start an agent, and ask it to create a file and run `uname -a`. Confirm
the file exists on the server and not on the Mac, the output names Linux, and the files pane shows
the new file.

**Acceptance Scenarios**:

1. **Given** a server the person can reach with SSH from this Mac, **When** they add it by its SSH name, **Then** the app connects using the person's existing SSH setup — their config, keys and agent — and asks for nothing SSH would not ask for.
2. **Given** a server that has never run this app, **When** it is added, **Then** the app puts what it needs on the server and starts it there, without the person running anything on the server themselves.
3. **Given** a connected server, **When** the person makes a new project, **Then** they can choose to put it on that server, then either pick a folder on the server or give a Git URL that is cloned on the server.
4. **Given** a project on a server, **When** the person starts an agent in it, **Then** the agent runs on the server, in the project's folder there, and everything it does — commands, edits, worktrees — happens on the server.
5. **Given** a project on a server, **When** the person opens its files pane, terminal, a touched file or a worktree, **Then** each shows the server's copy, and behaves as it does for a local project.
6. **Given** projects on the Mac and on a server, **When** the person looks at the project list, **Then** both are in the one list, and each server project says which server it is on.

---

### User Story 2 - Agents keep working when the Mac goes away (Priority: P1)

The person starts three agents on the server, closes the laptop, and takes a train. On the far side
they open the lid. The window reconnects by itself and shows the agents as they are now: two
finished, one waiting for an answer. The whole conversation from while they were away is there.

**Why this priority**: This is why the work should be on a server at all. A server agent that stops
when the laptop sleeps is a slower local agent.

**Independent Test**: Start an agent on a server with a task that takes several minutes. Put the
Mac to sleep (or cut its network) for longer than the task. Wake it, and confirm the window
reconnects without being asked, the agent finished while the Mac was away, and its full
conversation and outcome are shown.

**Acceptance Scenarios**:

1. **Given** agents running on a server, **When** the Mac sleeps, quits the app or loses its network, **Then** those agents carry on working on the server.
2. **Given** the connection to a server was lost, **When** it can be made again, **Then** the app reconnects by itself, without the person doing anything.
3. **Given** the app has reconnected, **When** the person looks at the server's projects, **Then** every agent shows its current state, and every message, tool call and outcome that happened while the Mac was away is present.
4. **Given** an agent on a server asked a question or for permission while the Mac was away, **When** the app reconnects, **Then** the question is waiting, answerable, exactly as if it had been asked while connected.
5. **Given** the connection is down, **When** the person looks at a server project, **Then** they can see that it is disconnected and since when, and see the last known state of its agents, and the app does not pretend to send a prompt or answer it cannot deliver.

---

### User Story 3 - A server that cannot be used says why (Priority: P2)

The host name is mistyped, or the key is not loaded, or the server is an architecture or system the
app cannot run on, or no agent CLI is installed there. The person is told, in a sentence, what is
wrong and what to do about it, and nothing half-set-up is left on the server.

**Why this priority**: SSH fails in many ways and each is fixable by the person in a minute — if
they are told which one it is. A spinner that never ends sends them back to the terminal for good.

**Independent Test**: Try each of: an unknown host name; a host whose key is refused; a host whose
SSH key fingerprint has changed; a host that is not Linux on x86-64 or ARM64; a host with no agent
CLI installed. Confirm each is refused or flagged with a message naming the problem, and that a
failed setup leaves nothing of the app's behind on the server.

**Acceptance Scenarios**:

1. **Given** a host SSH cannot reach or cannot log in to, **When** the person adds it, **Then** they are shown SSH's reason in plain words, and the server is not added.
2. **Given** a host the Mac has never connected to, **When** the app first connects, **Then** it shows the host's key fingerprint and asks the person to trust it before going further.
3. **Given** a host whose key no longer matches the one the Mac has on record, **When** the app connects, **Then** it refuses, and says the key has changed.
4. **Given** a server of a kind the app cannot run on, **When** it is added, **Then** the app says what the server is and what it needs, and installs nothing.
5. **Given** a connected server, **When** the person starts an agent, **Then** they are offered only the agent runtimes installed on that server, and a server with none says so and how to fix it.
6. **Given** setup on a server failed partway, **When** it has failed, **Then** nothing the app put on the server is left behind.

---

### User Story 4 - The server stays in step with the app (Priority: P2)

The person updates the app on the Mac. Next time they connect to their server, the app notices the
server is running an older version and replaces it — but not while an agent there is in the middle
of something.

**Why this priority**: Without it, the first app update breaks every server, or silently leaves it
speaking an older protocol.

**Independent Test**: Connect a server, then connect with a newer build of the app. Confirm the
server is brought up to the new version, and that if an agent was mid-turn at the time, the swap
waits until it finishes and its conversation survives the swap.

**Acceptance Scenarios**:

1. **Given** a server running an older version than the app, **When** the app connects and no agent there is mid-turn, **Then** the server is updated and restarted, and every project and conversation on it is still there afterwards.
2. **Given** a server running an older version with an agent mid-turn, **When** the app connects, **Then** the update waits until nothing is mid-turn, and the window says an update is waiting.
3. **Given** a server running a newer version than the app, **When** the app connects, **Then** it does not downgrade it, and says the app needs updating.

---

### User Story 5 - Remove a server (Priority: P3)

The person is done with a server. They remove it from the app. Its projects leave the list, and the
app's own process on the server is stopped. Their code on the server is not touched.

**Why this priority**: Needed for the feature to be tidy, but a server that stays listed does no
harm.

**Independent Test**: Remove a connected server with a project and a stopped agent. Confirm its
projects are gone from the list, the app's process on the server is no longer running, and the
project folders on the server are unchanged.

**Acceptance Scenarios**:

1. **Given** a server with no agent running, **When** the person removes it, **Then** its projects leave the list and the app's process on the server is stopped.
2. **Given** a server with agents running, **When** the person removes it, **Then** they are told how many will be stopped and asked to confirm first.
3. **Given** a removed server, **When** the person looks on it, **Then** their project folders, repositories and worktrees are exactly as they were.
4. **Given** the person removes a server, **When** asked, **Then** they can choose to also remove what the app installed on it, and nothing else.

---

### Edge Cases

- The same server is added from two Macs: both see the same projects and agents, as two windows on one Mac do today.
- The SSH connection drops in the middle of a prompt being sent: the prompt is either delivered once or reported as not sent — never sent twice, never silently lost.
- The server reboots: when it is back, the app starts its daemon again on next connect, and agents that were running come back the way they do after a Mac restart today.
- The server's disk is full or the app's folder there is not writable: setup or the failing operation says so, rather than hanging.
- The person's SSH config uses a jump host, a non-default port or a custom identity: it works, because the app goes through the person's own SSH setup.
- The SSH key needs a passphrase that is not in the agent: the app says the key is locked and how to unlock it, rather than hanging on a hidden prompt.
- A local file is dragged or attached to a prompt in a server project: it is copied to the server so the agent can read it, or the app says it cannot be attached.
- "Open in Finder" / "Open in editor" on a server file: offered only where it can work, and otherwise not shown.
- The Mac's own daemon is stopped or restarting: server projects are unaffected, and vice versa.
- Two servers are connected at once: each is independent; one going down does not affect the other or the Mac's projects.
- The daemon on the server is left running with no Mac connected for days: it keeps its agents, and does nothing the Mac's daemon would not do on its own.

## Requirements *(mandatory)*

### Functional Requirements

**Hosts**

- **FR-001**: The person MUST be able to add a server by the name they use with SSH — an alias from their SSH configuration, or `user@host[:port]`.
- **FR-002**: The app MUST connect using the person's own SSH setup — their configuration, keys, agent, known hosts and jump hosts — and MUST NOT store SSH passwords, private keys or passphrases itself.
- **FR-003**: On first connection to a host with no known key, the app MUST show the host key fingerprint and require the person to trust it; on a changed host key it MUST refuse to connect.
- **FR-004**: The app MUST support Linux servers on x86-64 and ARM64 in this version, and MUST refuse, with a reason, any other system before installing anything.
- **FR-005**: The app MUST put everything it needs on the server itself, inside the person's home folder, without needing administrator rights, and MUST start it under the person's own account.
- **FR-006**: Nothing the app runs on the server MUST listen on a network port; the only way in MUST be through the person's SSH login, and what it leaves on the server MUST be readable only by that account.
- **FR-007**: The app MUST show, for each server, whether it is connected, connecting, disconnected (and since when), or unusable (and why).
- **FR-008**: The person MUST be able to remove a server; this MUST stop the app's process there, MUST NOT touch any project folder, and MAY, if the person asks, remove what the app installed.

**Projects and agents on a server**

- **FR-009**: When making a new project, the person MUST be able to choose which host it lives on — this Mac or any connected server — and then pick a folder on that host or give a Git URL to clone on that host.
- **FR-010**: Server projects MUST appear in the same project list as local ones, each marked with the server it is on.
- **FR-011**: An agent in a server project MUST run on that server, with the project's folder there as its working folder, using an agent runtime installed on that server.
- **FR-012**: When starting an agent in a server project, the runtimes offered MUST be those the server has, not those the Mac has.
- **FR-013**: Everything the app does for a local project — chat, permissions and questions, files pane, live pages, terminal, touched files, worktrees, suggested prompts, outcomes, stop, archive, workflows, and costs — MUST work for a server project, acting on the server.
- **FR-014**: Spending totals MUST include agents on servers, and MUST be able to show which server a cost came from.
- **FR-015**: A file the person attaches to a prompt in a server project MUST reach the agent on the server, or the app MUST say it cannot.
- **FR-016**: Actions that only make sense on the Mac (open in Finder, open in a Mac app, keep the Mac awake) MUST be hidden or disabled for server projects rather than acting on the wrong machine.

**Surviving disconnection**

- **FR-017**: Agents on a server MUST keep running when the Mac sleeps, loses its network, or quits the app.
- **FR-018**: The app MUST reconnect to a server by itself when it can, and on reconnecting MUST show everything that happened while it was away, with nothing missing and nothing shown twice.
- **FR-019**: While a server is disconnected, its projects MUST show their last known state marked as not current, and the app MUST NOT accept a prompt, answer or action for it as if it would be delivered.
- **FR-020**: A prompt or answer sent at the moment a connection drops MUST be delivered exactly once or reported as not sent.
- **FR-021**: If the server's process is not running when the app connects (for example after a server reboot), the app MUST start it, and agents MUST recover as they do after a Mac restart today.

**Versions**

- **FR-022**: On connecting, the app MUST check the version on the server; if it is older, the app MUST replace it, waiting until no agent there is mid-turn, and MUST keep every project and conversation across the swap.
- **FR-023**: If the server's version is newer than the app's, the app MUST NOT downgrade it and MUST tell the person to update the app.

**Failures**

- **FR-024**: Every failure to add, connect to, set up or use a server MUST be shown in a sentence naming the cause — unreachable host, login refused, locked key, changed host key, unsupported system, no runtimes, disk full — never an endless wait.
- **FR-025**: A setup that fails partway MUST leave nothing of the app's behind on the server.

### Key Entities

- **Host**: a machine the app's work can happen on. This Mac is one; each added server is another. A server host has the SSH name it was added by, its system and architecture, its trusted key, its connection state, and the version of the app running there.
- **Project**: unchanged, except that it now belongs to a host. Its folder is a path on that host.
- **Agent**: unchanged. It runs on its project's host, with a runtime found on that host.
- **Server install**: what the app puts on a server — its own process and its state — kept in one place in the person's home folder there, so it can be updated or removed as one.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person with a Linux server they can already SSH into, with an agent CLI installed and logged in there, can go from "add server" to an agent running on it in under 2 minutes, without typing anything on the server.
- **SC-002**: An agent started on a server finishes its work with the Mac asleep or offline for the whole of it, and 100% of its conversation is visible after reconnecting.
- **SC-003**: After the Mac's network comes back, the window is showing current server state within 10 seconds, with no action from the person.
- **SC-004**: In a server project, chat, files pane and terminal respond to the person as quickly as they do in a local project on a connection with under 100 ms round trip — no step feels slower than one round trip plus the local time.
- **SC-005**: Each of the failure cases in User Story 3 produces a message naming the cause within 30 seconds, and none leaves the app's files on the server.
- **SC-006**: A port scan of a server running the app finds nothing new listening.
- **SC-007**: Updating the app and reconnecting brings the server to the same version with no conversation lost, in every trial where no agent was mid-turn, and waits in every trial where one was.

## Assumptions

- **Servers are Linux on x86-64 or ARM64** (Alex's choice). A Mac as a server, and other systems, are out of scope for this version.
- **A project lives on one host** (Alex's choice). Local and server projects share one list; there is no mode that switches the whole window to a server.
- **Key-based SSH only.** The app relies on the person's SSH agent and keys; a server that can only be reached with a typed password is out of scope, and the app says so.
- **Agent runtimes are the person's to install and log in on the server.** The app finds what is installed and uses it, and does not copy the Mac's credentials or logins to the server. It may point to the server's terminal as the place to log in.
- **Git credentials on the server are the server's.** Cloning a private repository there uses whatever access the server has, not the Mac's.
- **iPhone and iPad see only the Mac's projects in this version.** The remotes reach the Mac's daemon through the existing mailbox; reaching server projects from a phone (through the Mac, or directly) is a follow-up.
- **A server is used by one person.** Several Macs belonging to the same person may connect; sharing a server's daemon between different people is out of scope.
- The server has a normal home folder, a working shell, and outbound network access for whatever the agents need.
- Existing features — worktrees (030), project from a Git URL (027), surviving a restart (025), costs (010/012), workflows (008/017) — are reused on the server as they are, not rebuilt.
