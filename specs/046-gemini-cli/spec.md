# Feature Specification: Gemini CLI as a Fifth Runtime

**Feature Branch**: `agents/speckit-specify-support-gemini`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "support for Gemini CLI"

## Why this feature exists

The app starts four runtimes: Claude, Grok, Copilot and Cursor. Gemini CLI is Google's coding
agent, and people who already pay for Gemini, or who use its free tier, have no way to run it
here. They have to keep a terminal open next to the app, where none of its work shows up in the
app's lists, on the phone, in workflows or in leases.

Gemini CLI speaks the same agent protocol (ACP) as the four runtimes the app already has. It
was the first agent to speak it. So Gemini can be added as another runtime, not built as a
special case. The work is in the parts that differ between runtimes: how it is installed, how it
signs in, which of its own tools overlap with the app's, how it asks questions, and how it gets
onto a server.

**This feature makes Gemini a runtime like the others**, on the Mac and on servers, with
nothing for the person to install beyond what Claude already needs.

## Defaults taken *(Alex to confirm or overturn)*

Alex settled the first two on 2026-09-25. The rest are defaults so that the spec is complete,
and each is marked *(default Dn)* where it is used.

- **D1. Installed by the app's start-up installer.** Gemini CLI, pinned, with a pinned Node to
  run it, is one of the programs the app's start-up installer fetches, checks and keeps up to
  date. That installer is its own feature, planned in another lane (the one Codex, 047, also
  depends on). This spec does not define how it downloads, verifies, updates or reports
  progress. It only requires that Gemini is covered, and that nothing else is needed: no Node,
  no npm, no npx, no `gemini` on the PATH. The app never uses or replaces a `gemini` the person
  installed themselves. *(Settled by Alex, 2026-09-25: first npx, then moved to the installer.)*
- **D2. On the Mac and on servers.** Servers get Gemini the way 043 gives them Claude: a
  pinned toolset installed on demand, and a credential from the Mac's Settings lent to each
  run and never written to the server's disk. *(Settled by Alex.)*
- **D3. On the Mac, Gemini uses its own sign-in.** Whatever Gemini CLI already has in the
  person's home (a Google account sign-in or an API key in its environment) is what an agent on
  the Mac uses, as with 043's D5 for Claude. A key in Settings is for servers only.
- **D4. A server credential is a Gemini API key.** Settings takes a Gemini API key from Google
  AI Studio. A Google account sign-in (a browser sign-in whose tokens live in the Mac's
  `~/.gemini`) is not copied to servers in this version. *Alternative: lend the Mac's Google
  account sign-in too.*
- **D5. Pinned, and moved on by the installer.** Each app version names one Gemini version,
  the same on the Mac and on servers. Moving it on is the start-up installer's job, under its
  rules. The one rule Gemini adds: a running Gemini agent keeps the build it started on until
  it ends.
- **D6. The person's own Gemini settings are left alone.** The app does not edit
  `~/.gemini/settings.json` or any other file of Gemini's in the person's home. Anything the app
  needs to set for its own agents (its tools, which of Gemini's tools are removed) is passed
  when the app starts that agent, and holds for that agent only.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a Gemini agent on the Mac (Priority: P1)

The person has Gemini CLI signed in on their Mac, or has never installed it at all. In the start form, **Gemini** is in the runtime list beside Claude, Grok, Copilot and
Cursor. They choose it and type a prompt. If the start-up installer has not finished
installing Gemini yet, the agent says so and starts as soon as it has, so a first start reads as
progress and not as a hang. Then Gemini
works like any other runtime: it replies as it thinks, calls tools, asks permission where it
asks, shows the diffs of the files it changes, reports cost and usage as far as Gemini says
them, can be stopped mid-turn, and can be resumed later with its history.

**Why this priority**: It is the request. Without it the other stories have nothing to act on.

**Independent Test**: On a Mac with a signed-in Gemini (or none installed, and nothing else installed either), start a
Gemini agent in a project and ask it to create a file and run `ls`. The reply streams in, the
tool calls show, the file appears in the changes, and a later resume continues the conversation.

**Acceptance Scenarios**:

1. **Given** the start form, **When** the person opens the runtime list, **Then** Gemini is listed with the other runtimes, and a new conversation can be started with it *(default D1)*.
2. **Given** a Mac where the start-up installer has not yet installed Gemini, **When** the person starts a Gemini agent, **Then** the agent shows that Gemini is still being installed, and the first reply follows once it is, without the person doing anything else.
7. **Given** a running Gemini agent, **When** the installer moves Gemini to a newer build, **Then** that agent is not interrupted and keeps its build until it ends *(default D5)*.
3. **Given** a running Gemini agent, **When** it edits files, runs commands or asks permission, **Then** each shows in the conversation the way the same act from another runtime does, and a permission ask can be answered on the Mac or phone.
4. **Given** a Gemini agent mid-turn, **When** the person stops it, **Then** the turn ends and the agent can be given a new prompt.
5. **Given** a stopped or parked Gemini agent, **When** the person resumes it, **Then** it continues the same conversation with its history, if Gemini supports loading a conversation; if not, the app says that resume starts afresh and does not claim otherwise.
6. **Given** a Gemini turn that reports tokens or cost, **When** it ends, **Then** usage shows as for other runtimes; where Gemini reports nothing, nothing is shown rather than a zero.

---

### User Story 2 - Sign Gemini in (Priority: P2)

The person starts a Gemini agent without having signed Gemini in. They do not get a silent
failure or an empty reply. The runtime menu says **Needs signing in** beside Gemini, and **Sign
in, sign out, providers…** opens the same sheet the other runtimes use, offering the sign-in
choices Gemini itself gives (a Google account, a Gemini API key, Vertex AI) with Gemini's own
advice under each.

**Why this priority**: Most people who try Gemini here for the first time will not be signed in.
A start that fails without a word would make Gemini look broken.

**Independent Test**: With Gemini's sign-in removed from the Mac's home, start a Gemini agent:
the app says it needs signing in and offers the sheet. Sign in from the sheet. A new turn works.

**Acceptance Scenarios**:

1. **Given** Gemini not signed in on the Mac, **When** the person starts a Gemini agent, **Then** the agent says Gemini needs signing in, with a way to do it, and never waits forever or shows only "stopped answering".
2. **Given** the sign-in sheet for Gemini, **When** it opens, **Then** it shows where Gemini stands (**Signed in and ready**, **Installed, and needs signing in**, or **Not asked yet**) and Gemini's own sign-in choices.
3. **Given** a sign-in choice that Gemini can only complete in a browser or a terminal, **When** the person picks it, **Then** the app opens the browser, or hands over the exact command with **Open Terminal** and **Copy**, as it does for Copilot.
4. **Given** Gemini signed in, **When** the person signs it out from the sheet, **Then** the next start says it needs signing in again, if Gemini offers a way to sign out over ACP; if not, the sheet shows no sign-out button, as for Cursor.

---

### User Story 3 - The app's own tools and scoping (Priority: P3)

A Gemini agent works inside the app the way a Claude agent does. It has the app's tools: it ends
its turn with a report, asks questions, leases resources, waits for events, and starts and runs
workflows. Gemini's own tools that duplicate the app's are taken away for the conversations the
app starts, so that its work stays where the app can see it. Where one of its tools cannot be
taken away, it is named as residue, the way three of Cursor's are. When a Gemini agent needs to
ask the person something mid-turn, the question reaches the person as a card if Gemini has a way
to ask over ACP. If it does not, it ends its turn with the question, and the agent shows
**Waiting on your answer**, as Grok does.

**Why this priority**: Without it Gemini runs, but outside the app's rules. Its turns end
without a report, it cannot lease or wait, and it can schedule or delegate work the app never
sees. The runtime policy table must also cover every runtime, or a test fails. So this story
has to ship with P1 before Gemini is offered.

**Independent Test**: Start a Gemini agent and ask it to list the tools it has. The app's tools
are listed and the removed ones are not. Ask it to end its turn with a report, to lease a
resource and to ask a question. Each arrives in the app as it does for Claude.

**Acceptance Scenarios**:

1. **Given** a Gemini agent, **When** it starts, **Then** it is given the app's tools and the same briefing as other runtimes.
2. **Given** a Gemini agent, **When** it ends a turn, **Then** it reports the turn's outcome through the app's tool, as Claude does.
3. **Given** Gemini's own tools that overlap with the app's (scheduling, starting other agents, notifications, saving documents elsewhere), **When** the app starts a Gemini agent, **Then** those are removed, or, where they cannot be, named as residue in the policy and in the briefing.
4. **Given** a Gemini agent that needs an answer mid-turn, **When** it asks, **Then** the person sees a question card if Gemini can ask over ACP, or otherwise the agent shows **Waiting on your answer** with the question.
5. **Given** the same Gemini CLI started from Terminal, **When** the person uses it there, **Then** it has every tool it always had, and the app has changed none of its settings *(default D6)*.

---

### User Story 4 - Gemini on servers (Priority: P4)

The person has a bare Linux server added as in 043, and a Gemini API key in Settings. When they
start a Gemini agent in a project on that server, the server installs Gemini's pinned toolset
the first time, with its progress in the set-up checklist. The agent then signs in with the key
lent from the Mac. The key is never written to the server's disk.

**Why this priority**: It extends 043 to a second runtime. That matters for the ephemeral servers
043 is about, but the Mac comes first.

**Independent Test**: With a Gemini API key in Settings and a Linux server with nothing on it,
start a Gemini agent in a server project and ask it to run `uname -a`. The reply comes back.
Afterwards, a search of the server's disk finds the key nowhere.

**Acceptance Scenarios**:

1. **Given** Settings' runtime credentials, **When** the person opens them, **Then** Gemini is listed beside Claude, with the kind of key it takes, where to get one, and a field to paste it *(default D4)*.
2. **Given** a pasted Gemini key, **When** it is saved, **Then** the app checks it with Google and says in words whether it works, and keeps it only in the Mac's Keychain.
3. **Given** a server without Gemini, **When** Gemini is first needed there, **Then** the server installs the pinned toolset, checks it against the app's checksums, and shows its progress; a failed install names its cause and leaves nothing half-installed *(default D2, D5)*.
4. **Given** a Gemini agent starting on a server, **When** it signs in, **Then** the key reaches that run only, and is not written to the server's disk, any log or any transcript, or sent to any server for another runtime.
5. **Given** a server marked "use this server's own sign-in only" (043), **When** a Gemini agent starts there, **Then** no key is sent, and Gemini's own sign-in on the server is used.
6. **Given** no Gemini key in Settings and no sign-in on the server, **When** the person starts a Gemini agent there, **Then** the app asks for the key in place before starting.

---

### Everywhere a runtime is chosen

Gemini is offered wherever another runtime is: a workflow's steps, the phone's and iPad's start
forms, the runtime menu above the prompt, and `start_agent` from another agent. On a server
project it is offered when it is installed there or can be installed there (User Story 4).

### Edge Cases

- **Gemini not installed yet.** A download that fails, a download that does not match, or being offline when the app starts are the installer's to handle. Gemini's part is to say, when an agent is started, which of these happened, and never to show "stopped answering" instead.
- **A `gemini` of the person's own.** One on the PATH, from npm or Homebrew, is neither used nor changed. Their terminal keeps running theirs.
- **A Gemini release changes its ACP flag or drops it.** The agent says Gemini did not start in a mode the app can talk to, and names the version. It does not hang. The plan's research records the flag measured, and a check script can re-measure it.
- **Quota or rate limit.** Gemini refuses the turn because of a quota or rate limit (common on the free tier). The turn ends with that reason in a sentence, not as a crash, and the agent can be prompted again later.
- **Free-tier model fallback.** Gemini switches to a smaller model in the middle of a session when the larger one's quota runs out. The model shown for the agent follows what Gemini reports, if it reports it. The app never claims a model that is not being used.
- **The person's own Gemini settings.** `~/.gemini/settings.json`, and anything else of Gemini's in the person's home, is never written by the app. MCP servers the person configured there are left as they are. Whether Gemini loads them in the app's agents is recorded in the plan's research *(default D6)*.
- **A key in the environment.** On the Mac, `GEMINI_API_KEY` or `GOOGLE_API_KEY` in the environment the app was launched with is Gemini's own sign-in and is used as such *(default D3)*. On a server, a key from Settings replaces any key in the server's environment for that run (043 D1).
- **A Google account sign-in on the Mac, nothing in Settings, and a server agent.** The app asks for a Gemini API key in place. It does not copy the Mac's Google sign-in to the server *(default D4)*.
- **A key Google refuses.** The agent stops with a sentence saying the key was refused, and a way to replace it, distinct from any other failure (043 FR-016).
- **Unsupported attachments.** A picture attached for a Gemini agent goes as a picture if Gemini says it takes pictures, and as a reference to the file if not. The app follows what Gemini says about itself when it starts.

## Requirements *(mandatory)*

### Functional Requirements

**Starting Gemini on the Mac**

- **FR-001**: The app MUST list Gemini among the runtimes it can start, everywhere a runtime is chosen: the Mac's start form and runtime menu, the phone and iPad start forms, workflow steps, and `start_agent`.
- **FR-002**: The pinned Gemini CLI, and the Node it runs on, MUST be among the programs the app's start-up installer installs on the Mac. Gemini MUST need nothing installed beforehand (no Node, npm or `gemini`), and the app MUST NOT use, change or remove a Gemini the person installed themselves *(default D1)*.
- **FR-003**: A Gemini agent started before the installer has Gemini ready MUST say it is waiting for the install and start when it is ready; one started after the install failed MUST say why, in the installer's words.
- **FR-003a**: A running Gemini agent MUST keep the build it started on when the installer moves Gemini to a newer one *(default D5)*.
- **FR-004**: A Gemini agent MUST show replies, tool calls, permission asks, file changes, stop and resume the way the app shows them for other runtimes, limited only by what Gemini reports over ACP.
- **FR-005**: Usage and cost MUST be shown where Gemini reports them, and left out (not shown as zero) where it does not.
- **FR-006**: What Gemini can do in the app (pictures, sign-in, sign-out, resume, model choice) MUST follow what it says about itself when it starts, not a list kept by the app.

**Signing in**

- **FR-007**: A Gemini agent that cannot start because Gemini is not signed in MUST say so and offer the runtime sign-in sheet; it MUST NOT fail silently or wait forever.
- **FR-008**: The sign-in sheet MUST show Gemini's own sign-in choices and advice, and hand over a browser or terminal step where Gemini needs one.
- **FR-009**: On the Mac, a Gemini agent MUST use Gemini's own sign-in, and a key in Settings MUST NOT be sent to agents on the Mac *(default D3)*.

**The app's tools and scoping**

- **FR-010**: A Gemini agent MUST be given the app's tools and the same briefing as other runtimes.
- **FR-011**: The runtime tool policy MUST have an entry for Gemini, which removes Gemini's tools that duplicate the app's (standing arrangements, starting agents, notifications, artefact stores) and names as residue any that cannot be removed. The policy MUST cover every runtime in the catalog, and a test MUST say so.
- **FR-012**: A Gemini agent's mid-turn question MUST reach the person as a card if Gemini can ask over ACP, and otherwise as **Waiting on your answer** with the question.
- **FR-013**: The app MUST NOT write to `~/.gemini/settings.json` or any other file of Gemini's in the person's home; everything it sets for its own agents MUST be passed when it starts that agent *(default D6)*.

**Gemini on servers**

- **FR-014**: Settings' runtime credentials MUST list Gemini, take a Gemini API key, check it with Google on save and say in words whether it works, and keep it only in the Mac's Keychain, shown masked afterwards *(default D4)*.
- **FR-015**: A server MUST install Gemini's pinned toolset on demand, from official sources, checked against checksums the app carries, with progress in the set-up checklist; an incomplete install MUST never be used *(default D2, D5)*.
- **FR-016**: A Gemini key MUST reach a server only as part of starting Gemini there, for that run, and MUST NOT be written to the server's disk, any log, transcript or crash report, or sent for any other runtime.
- **FR-017**: 043's rules for servers MUST hold for Gemini as they do for Claude: a server's "own sign-in only" mark, asking for the key in place when none is usable, a refused key shown as its own failure, and a rebuilt server set up again on confirmation.

**Failures**

- **FR-018**: Gemini not installed, a changed ACP mode, a quota or rate limit, and a refused key MUST each end with a sentence naming the cause, never an endless wait or "stopped answering".

### Key Entities

- **Gemini runtime**: a fifth entry in the app's runtime list: its name, how it is started (the installed Gemini CLI on its installed Node, ACP mode), and what it says about itself when it starts.
- **Gemini tool policy**: which of Gemini's tools are removed for the app's agents, which remain as residue and why, and how its questions reach the person.
- **Gemini credential**: a Gemini API key, for servers only, kept in the Mac's Keychain, masked when shown, with when it was added and when it last worked (043's runtime credential, gaining a second kind).
- **Gemini toolset**: the pinned Gemini CLI package and a Node to run it, with versions and checksums. On the Mac it is an entry in the start-up installer's list. On a server it is one of 043's installed tools, beside Claude's, replaced as a whole.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Mac with a signed-in Gemini and nothing else installed, once the start-up installer has finished, a person who has never used Gemini in the app gets a Gemini agent's first reply within 30 seconds of choosing it, having run no command.
- **SC-002**: A Gemini start takes no more than 5 seconds longer to its first reply than a Claude start on the same Mac.
- **SC-003**: Every failure in the edge cases above shows as a sentence naming its cause; none shows as an endless wait or as "stopped answering".
- **SC-004**: After a day of Gemini agents in the app, the person's `~/.gemini` settings are byte for byte what they were before.
- **SC-005**: From a bare Linux server, a person with a Gemini key in Settings gets a Gemini agent's first reply within 5 minutes, having run no command on the server; afterwards a search of the server's disk and the Mac's logs finds the key in neither.
- **SC-006**: A Gemini agent's turns end with the app's outcome report in at least 9 of 10 turns, as measured for the other runtimes that have the app's tools.

## Docs *(mandatory)*

- `docs/reference/runtimes.md` — change: "four" becomes "five"; add a Gemini row (command, pictures, sign-in, app tools, notes on questions, quota and residue).
- `docs/how-to/sign-a-runtime-in.md` — change: name Gemini among the runtimes, and add its sign-in choices (Google account, API key).
- `docs/how-to/add-a-linux-server.md` — change: Gemini installs on a server as Claude does; where to paste a Gemini key.
- `docs/reference/settings.md` — change: runtime credentials entry lists Gemini API key.

## Assumptions

- Gemini CLI's ACP mode, the exact flag that starts it, its package name, its tool names, and whether it can ask a question or sign out over ACP are measured in the plan's research against a real Gemini CLI, not taken from this spec. Gemini is not installed on this Mac today.
- Gemini CLI is published on npm as JavaScript and needs Node 20 or later (measured: 0.61.0), so its installer entry carries a pinned Node beside it, on the Mac as on servers.
- **Depends on the start-up installer**, a separate feature being planned in another lane. That feature owns downloading, checking, updating, progress and failure reporting for the app's runtime programs on the Mac. This spec adds Gemini to its list, can be planned and built alongside it (everything but the Mac install), but cannot ship on the Mac before it.
- Gemini accepts an API key through its environment, so a server can be signed in by lending the key per run as 043 does for Claude.
- Builds on 043 (runtime credentials, server toolsets, "own sign-in only"), which is merged. This spec extends 043's D3 "Claude first" to Gemini, but not yet to Grok, Copilot or Cursor.
- Codex and other runtimes remain out of scope.
