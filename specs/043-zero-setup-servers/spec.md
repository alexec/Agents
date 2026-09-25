# Feature Specification: Zero-Setup Servers

**Feature Branch**: `043-zero-setup-servers`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Something to consider here is that these remote environments are often ephemeral. Either way, we should not require the user to do set-up. To do this we should install the binaries they need (e.g. have the agentd download on demand) and allow the user to provide credentials. This could be in the form of a settings where the user adds an access token to be used on the remote system."

## Why this feature exists

037 put agents on servers, but it left the server's half of the work to the person. Before an
agent can start there, someone has to log in to the server, install Node, install the agent
runtime, and sign that runtime in, usually through a browser flow in a terminal the app never
shows. The app's own part (its daemon) already installs itself; everything the agent needs to
think does not.

That is tolerable for one long-lived box under a desk. It is not tolerable for the servers people
actually reach for now: a cloud VM made for an afternoon, a container rebuilt from an image every
morning, a dev box that is wiped when it is idle. On those, the set-up is lost every time the box
is, and ten minutes of terminal work stands between the person and an agent, again and again.

**This feature makes a bare server enough.** If the person can reach it with SSH and it can reach
the internet, adding it in the app is the whole of the set-up: the app installs what the agent
needs, and the agent signs in with a credential the person gave the app once, on the Mac.

## Defaults taken *(Alex to confirm or overturn)*

The request left these open. Each has a default so the spec is complete; each is marked where it
is used as *(default Dn)*.

- **D1. Credentials are an access token per runtime, pasted in the Mac's Settings.** Kept only on
  the Mac, in its secure store. Handed to the runtime when an agent starts on a server, and never
  written to the server's disk. *Alternative: copy the sign-in the runtime already has on the Mac.*
- **D2. The server downloads what it needs itself**, from the runtimes' official sources, at
  versions and checksums the app names. The server needs the internet anyway to reach its model.
  *Alternative: the Mac downloads once and sends it over SSH, which works behind a server firewall.*
- **D3. Claude first.** This version makes Claude need no set-up; Copilot, Cursor and Grok keep
  037's behaviour (used if installed and signed in on the server) until a later version.
- **D4. 037 merges on its own**, before this; this feature changes 037's assumption that
  "runtimes are the person's to install and log in on the server".
- **D5. A token in Settings is for servers only.** Agents on the Mac keep using the sign-in they
  have on the Mac. *Alternative: one token used everywhere.*

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A bare server runs a Claude agent (Priority: P1)

The person has a fresh Linux server: SSH works, nothing else has been done to it. They have
already put their Claude token in Settings. They add the server as in 037. While it sets up, the
checklist shows a step for installing Claude, with its progress. They make a project on the
server and start a Claude agent. It answers. They never opened a terminal on the server.

**Why this priority**: It is the request. Every other story makes it survive real life.

**Independent Test**: Create a Linux server with only an SSH login and internet access (no Node, no
agent CLI, no sign-in). With a Claude token in Settings, add it, add a folder there as a project,
and ask a Claude agent to create a file and run `uname -a`. The reply comes back, the file exists
on the server, and no command was run on the server by hand.

**Acceptance Scenarios**:

1. **Given** a server with no agent runtime and a Claude token in Settings, **When** the person adds the server, **Then** the set-up checklist installs what Claude needs on the server, shows its progress, and ends with Claude ready.
2. **Given** that server, **When** the person starts a Claude agent in a project on it, **Then** the agent signs in with the token from Settings and answers, with nothing done on the server by the person.
3. **Given** a server that already has Claude installed and signed in by the person, **When** it is added, **Then** the app installs nothing for Claude and uses what is there, except that a token in Settings is used in preference to the server's own sign-in *(default D1)*.
4. **Given** a server where the install cannot finish (no internet, too little disk, a download that does not match its checksum), **When** it is set up, **Then** the checklist names the cause in a sentence, Claude is not offered on that server, and nothing half-installed is left to be used.

---

### User Story 2 - Give the app a credential once (Priority: P1)

In Settings, the person finds a place for runtime credentials. For Claude it says what kind of
token it takes and how to get one (e.g. the command that makes a long-lived token), and has a
field to paste it. After pasting, the app checks the token and says whether it works. The person
can replace or remove it at any time. The token is never shown again in full.

**Why this priority**: Without a credential, an installed runtime is no use; the two stories ship together.

**Independent Test**: Paste a valid token: Settings says it works. Paste a revoked one: Settings
says it was refused. Remove it: servers show Claude as needing a token. Search the Mac's
preferences and logs, and every server's disk after an agent has run: the token is in none of them.

**Acceptance Scenarios**:

1. **Given** Settings, **When** the person opens the credentials section, **Then** each runtime the app can install on a server is listed, with whether a token is set, what kind of token it takes and where to get one.
2. **Given** a pasted token, **When** it is saved, **Then** the app checks it with the runtime's provider and says in words whether it works, and keeps it only in the Mac's secure store *(default D1)*.
3. **Given** a saved token, **When** the person looks at it later, **Then** it is shown masked, with when it was added and when it last worked, and can be replaced or removed.
4. **Given** a server agent starting, **When** it signs in, **Then** the token reaches that agent's runtime for that run only, and is not written to any file on the server, not written to any log or transcript, and not sent to any server for a runtime that is not starting.
5. **Given** no Claude token in Settings, **When** the person starts a Claude agent on a server that has no sign-in of its own, **Then** the app asks for the token right there, in place, rather than starting an agent that will fail.

---

### User Story 3 - A server that comes back empty (Priority: P2)

The person's server is rebuilt overnight at the same address: same name, blank disk, new host key.
Next time the window connects, it notices this is a different machine at a known name. It shows
the new host key and asks the person to confirm the server was rebuilt. Once they do, it sets the
server up from scratch — daemon and Claude — and the server's projects, which lived on the old
disk, are shown as gone rather than as offline forever.

**Why this priority**: Ephemeral servers are the reason for the feature; without this, each rebuild ends in 037's hard "host key changed" refusal and a manual clean-up.

**Independent Test**: Add a server and run an agent there. Destroy and recreate the server at the
same address. Relaunch the window: it asks to confirm a rebuilt server, shows the new key, and
after confirming, a new Claude agent runs on it with no other action. The old projects say they
are gone.

**Acceptance Scenarios**:

1. **Given** a known server whose host key has changed, **When** the window connects, **Then** it does not connect silently; it shows the new fingerprint and offers "This server was rebuilt" as an explicit choice beside Cancel.
2. **Given** the person confirms a rebuild, **When** set-up runs, **Then** everything the app needs is installed again, as for a new server, with the same checklist.
3. **Given** a server whose app files have been wiped but whose key is unchanged, **When** the window connects, **Then** it re-installs without asking, as today for the daemon, and now for Claude too.
4. **Given** projects whose folders no longer exist on a rebuilt server, **When** the list is shown, **Then** they are marked as gone from the server, can be removed, and are never shown as merely offline.

---

### User Story 4 - Keep the tools current (Priority: P3)

When the app is updated and names newer runtime versions, each server's installed tools are
updated the next time it connects, waiting for no agent to be mid-turn, as 037 does for the
daemon. The person sees the update happen in the server's status and never has to ask for it.

**Why this priority**: A long-lived server would otherwise keep an old runtime forever; not needed for the first ephemeral use.

**Independent Test**: Connect a server with the tools at one version; update the app to one that
names a newer version; connect again with no agent running: the new version is installed and the
next agent uses it. Repeat with an agent mid-turn: the update waits until the turn ends.

**Acceptance Scenarios**:

1. **Given** a server with older tools than the app names, **When** it connects and no agent there is mid-turn, **Then** the tools are replaced and agents started after that use the new version.
2. **Given** an agent mid-turn, **When** the server connects, **Then** its tools are not changed under it; the update happens once the turn has ended.

---

### Edge Cases

- **No internet on the server** *(default D2)*: the install fails with "devbox can't reach the internet to download Claude"; the rest of the server still works for runtimes already there.
- **A download that does not match its checksum** is discarded and reported; nothing is installed from it.
- **Too little disk** for the tools: said before the download starts, with how much is needed and free.
- **A token that expires or is revoked** mid-use: the agent stops with "Claude refused the token in Settings. Replace it", with a way to Settings, not "Claude stopped answering". Other agents are unaffected until they next sign in.
- **An unsupported server** (not Linux x86-64 or ARM64, or a C library the runtime can't use): refused before anything is downloaded, naming what is missing.
- **The person already has their own Node on the server**: the app's copy lives apart from it and changes nothing about the person's own shell, PATH or profile.
- **Two windows (two Macs) using one server**: each sends its own token for the agents it starts; neither's token is left behind for the other.
- **A server where the person does not want tokens sent** (a shared box): the person can mark a server as "use the server's own sign-in only", and no token is ever sent to it.
- **Removing a server with purge** removes the installed tools too, and never the person's own Node or runtime.

## Requirements *(mandatory)*

### Functional Requirements

**Installing on demand**

- **FR-001**: For each runtime the app can install (Claude in this version, *default D3*), the app MUST be able to install everything the runtime needs on a Linux server that has only an SSH login and internet access, with no administrator rights and no action by the person on the server.
- **FR-002**: The app MUST install the runtime's needs when a server is set up if a credential for that runtime is in Settings, and otherwise when the person first chooses that runtime on that server.
- **FR-003**: What is installed MUST come from the runtime's official sources at versions the app names, and MUST be checked against checksums the app carries before use *(default D2)*.
- **FR-004**: Installed tools MUST live inside the app's own folder in the person's home on the server, MUST be readable only by the person's account, and MUST NOT change the person's shell configuration, PATH, or any tool they installed themselves.
- **FR-005**: A runtime that is already installed and working on the server MUST be used as it is, and the app MUST NOT install its own copy alongside.
- **FR-006**: Install progress MUST appear in the server's set-up checklist and status; every failure MUST be one sentence naming the cause (no internet, disk full, checksum mismatch, unsupported system), and a failed install MUST leave nothing that the app would later use.
- **FR-007**: When the app names newer tool versions than a server has, the server MUST be updated on connection once no agent there is mid-turn, as 037 does for its daemon.
- **FR-008**: Removing a server with purge MUST remove the tools the app installed, and nothing else.

**Credentials**

- **FR-009**: Settings MUST have a place, per installable runtime, to add, check, replace and remove a credential, saying what kind of credential it takes and how to get one *(default D1)*.
- **FR-010**: A saved credential MUST be kept only on the Mac, in its secure store, and MUST be shown only masked after saving.
- **FR-011**: On saving, the app MUST check the credential with the runtime's provider and say whether it works; it MUST show when a credential last worked.
- **FR-012**: A credential MUST reach a server only as part of starting that runtime there, for that run, and MUST NOT be written to the server's disk, to any log, transcript or crash report, or sent to a server for any other runtime.
- **FR-013**: A credential in Settings MUST be used on servers only; agents on the Mac MUST keep using the Mac's own sign-in *(default D5)*.
- **FR-014**: Where a server has its own sign-in and Settings has a credential, the Settings credential MUST be used *(default D1)*; the person MUST be able to mark a server "use this server's own sign-in only", after which no credential is sent to it.
- **FR-015**: Starting a runtime on a server with no usable sign-in MUST ask for the credential in place, before the agent starts, rather than failing after.
- **FR-016**: A credential the provider refuses MUST stop the agent with a sentence saying so and a way to replace it, distinct from any other failure.

**Servers that are rebuilt or wiped**

- **FR-017**: A known server whose host key has changed MUST NOT be connected to silently; the app MUST show the new fingerprint and offer the person an explicit "this server was rebuilt" choice, and only on that choice trust the new key and set the server up again.
- **FR-018**: A server whose app files are missing MUST be set up again on connection without asking, including its runtimes' needs under FR-002.
- **FR-019**: Projects whose folders no longer exist on a server MUST be shown as gone from that server and removable, never as offline.

### Key Entities

- **Runtime credential**: a secret for one runtime (e.g. Claude), with its kind, when it was added and when it last worked. Lives only on the Mac. Not tied to a server.
- **Installed tools**: what the app installed on one server for one runtime, with its version and checksum, and whether it is complete. Replaced as a whole, never patched.
- **Server sign-in preference**: per server, whether credentials from Settings may be sent to it.
- **Server** (037): now also carries, per installable runtime, whether its needs are installed, installing, failed (and why), or out of date.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a newly created Linux server with only SSH access and internet, a person with a Claude token already in Settings gets a Claude agent's first reply within 5 minutes of choosing Add a server, having run no command on the server.
- **SC-002**: Connecting again to a server that is already set up adds no more than 5 seconds over 037's connection time.
- **SC-003**: After a day's use across several servers, a search of every server's disk and of the Mac's logs, preferences and transcripts finds the token in none of them.
- **SC-004**: A server rebuilt at the same address is usable again with one confirmation and no other action, every time.
- **SC-005**: Every install or sign-in failure in the edge cases above is shown as a sentence naming its cause; none shows as an endless wait or as "stopped answering".
- **SC-006**: Adding a Claude token takes one paste and one confirmation, and the person knows within 10 seconds whether it works.

## Assumptions

- Builds on 037 (servers over SSH, the server daemon, set-up checklist, Settings ▸ Servers), which merges separately *(default D4)*. This spec replaces 037's assumption that "agent runtimes are the person's to install and log in on the server".
- Servers are Linux on x86-64 or ARM64 with a common C library, as in 037; others are refused.
- Claude can be signed in with a long-lived token the person makes themselves (for a subscription) or an API key, passed to the runtime when it starts; the app does not run the provider's browser sign-in on the server.
- A credential passed to a process can be read by other processes running as the same account on that server. That is the person's own account, and the app states this in Settings. Servers the person shares can be marked "own sign-in only" (FR-014).
- The phone and iPad do not start agents on servers in this version (037), so credentials live and are used from the Mac only.
- Copilot, Cursor and Grok keep 037's behaviour until a later version *(default D3)*.
- Git credentials for cloning private repositories on a server are out of scope; the person's SSH agent forwarding or the server's own set-up still covers them.
