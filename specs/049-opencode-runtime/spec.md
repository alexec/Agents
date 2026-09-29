# Feature Specification: OpenCode as a Runtime

**Feature Branch**: `agents/write-spec-adding-opencode`

**Created**: 2026-09-25

**Status**: Draft (resumed 2026-09-28; servers revised, see Session 2026-09-28)

**Input**: User description: "Add OpenCode (sst/opencode) as a built-in runtime."

## Why this feature exists

The app starts four runtimes: Claude, Grok, Copilot and Cursor. 046 adds Gemini and 047 adds
Codex. OpenCode is the open-source coding agent from the SST team (its repository has since
moved to `anomalyco/opencode`). Its draw is that it is not tied to one model vendor. One
program signs in to Anthropic, OpenAI, GitHub Copilot, OpenRouter, a local model or any of 75
others, and switches between them per conversation. People who use it today keep a terminal
open beside the app, and none of that work shows up in the app's lists, on the phone, in
workflows or in leases.

OpenCode speaks the agent protocol (ACP) itself, as `opencode acp`. Each release is one
self-contained program per platform, published on GitHub with a SHA-256 digest, with no Node to
carry. So the app can keep its own pinned copy, as 046 and 047 settled for Gemini and Codex, but
more simply. The work is in the parts where OpenCode differs:

- **Its name is not unique**, so a copy found on the PATH cannot be trusted (see *The name trap*).
- **Its sign-in is a terminal step, not an ACP step.**
- **It signs in to many providers, not one**, which shapes what a server can be lent.
- **It updates itself by default, and can share conversations to the web.**
- **Its question tool is switched off over ACP.**

**This feature makes OpenCode a runtime like the others**, on the Mac and on servers. The app
installs it itself on both, and the `opencode` it starts is always its own.

## Clarifications

### Session 2026-09-25

- Q: How should the app install OpenCode on the Mac? → A: The app's own pinned copy of the release program, in the app's folder, checked against GitHub's SHA-256 digest. OpenCode's install script is not used, and an `opencode` of the person's own is never used.
- Q: Should OpenCode be offered on servers (043) in this spec? → A: Yes, lending one provider's key per run.
- Q: Which key should a server's OpenCode agent be lent? → A: A provider and key of OpenCode's own in Settings ▸ Runtime credentials, not Claude's Anthropic key reused. *(Superseded 2026-09-28, below.)*

### Session 2026-09-28

- Q: Since 056 and the Codex key's removal lend servers the Mac's own sign-in, how should OpenCode reach servers? → A: Lend the Mac's OpenCode sign-in. D7's pasted provider key is withdrawn: no OpenCode entry in Settings ▸ Runtime credentials. A server run gets the Mac's `auth.json` in `OPENCODE_AUTH_CONTENT` for that run, never written to the server's disk (research R7). This reverses the old FR-023, which forbade lending `auth.json`.
- Probe (research.md): a fresh OpenCode works signed out with OpenCode Zen's free models; inline config removes `task` and `todowrite` with no residue; OpenCode asks for nothing by default, so the app passes permission rules for the agent's mode.

## The name trap *(the reason this spec exists as more than one catalog line)*

`RuntimeCatalog.swift`'s header records the Cursor trap: Cursor's docs call its program
`agent`, and `agent` on this Mac is Grok. OpenCode's trap is the same kind.

1. **Two programs are called `opencode`.** Until mid-2025, `opencode-ai/opencode` was a Go
   terminal agent whose binary was also `opencode`. It was archived at v0.0.55 (2025-06-27) and
   continues as Charm's **Crush**. That old binary is still on Macs that installed it through
   its Homebrew tap. It has no `acp` subcommand. The SST program (now `anomalyco/opencode`,
   1.18.32 on 2026-09-21) kept the name. A PATH lookup for `opencode` cannot tell the two apart.
2. **Two npm packages look right.** The real one is `opencode-ai`. A bare `opencode` on npm is
   not it.
3. **The vendor's installer lands outside the app's search path.** `curl -fsSL https://opencode.ai/install | bash`
   always installs to `~/.opencode/bin/opencode`, a folder hard-coded in the script.
   `LoginShellPath.fallbacks` does not search `~/.opencode/bin`. For zsh users, the script puts
   the folder on the PATH in `~/.zshrc`, which the app's login, non-interactive `zsh -lc` never
   reads. So "run the vendor's script, then look it up" would fail on a typical Mac.
4. **OpenCode also ships a desktop app** (`opencode-desktop-mac-*.dmg` in the same release). It
   is not the program the app starts.

**How this spec rules it out (D1):** the app does not look `opencode` up at all. It starts the
copy it installed itself, by full path, from the app's own folder. That copy is the release
asset for this Mac's architecture, checked against the digest the app carries. A program on
the PATH called `opencode`, the Go one, an old SST one, an npm one or a Homebrew one, is never
started, changed or removed. It also never makes OpenCode's row read as installed. That is
the same rule 046 D1 settled for Gemini. `LoginShellPath.fallbacks` therefore does not need
`~/.opencode/bin`.

## Defaults taken *(Alex to confirm or overturn)*

Alex settled D1, D2 and D7 on 2026-09-25. The rest are defaults so that the spec is complete,
and each is marked *(default Dn)* where it is used.

- **D1. The app's own pinned copy, only.** OpenCode is a row on 048's set-up page (**Install
  your agents** at start-up, Settings ▸ Agents, and under an empty project list). **Install**
  downloads the pinned release program for this Mac (`opencode-darwin-arm64.zip`, or
  `opencode-darwin-x64.zip`, or the `-baseline` build for Intel Macs without AVX2) from
  OpenCode's GitHub releases into the app's own folder, and checks it against the SHA-256 the
  app carries. **Retry** or **Open install page** follow a failure. Nothing is needed
  beforehand. Agents always run the app's copy. An `opencode` the person installed is never
  used, changed or removed, even when it is on the PATH. *(Settled by Alex, 2026-09-25, over
  running OpenCode's own install script.)*
- **D2. On the Mac and on servers.** Servers get OpenCode the way 043 gives them Claude: the
  pinned Linux program installed on demand, and the Mac's sign-in lent to
  each run and never written to the server's disk. *(Settled by Alex, 2026-09-25.)*
- **D7. A server borrows the Mac's OpenCode sign-in.** Each OpenCode run on a server is given
  the providers OpenCode is signed in to on the Mac, in `OPENCODE_AUTH_CONTENT` for that run
  only, never written to the server's disk. There is no OpenCode entry in Settings ▸ Runtime
  credentials. Until a rotating sign-in (a ChatGPT or Copilot account) is measured, only
  entries that do not rotate (provider keys) are lent, and the sheet names the ones that are
  not *(default)*. The Zen free models need nothing lent. *(Revised by Alex, 2026-09-28, over
  the pasted key he settled on 2026-09-25.)*
- **D3. On the Mac, OpenCode's own sign-in, left where it is.** An agent on the Mac uses
  whatever providers OpenCode is signed in to in the person's home
  (`~/.local/share/opencode/auth.json`). That sign-in is shared with any OpenCode of the
  person's own, so a provider signed in in either works in both. It also uses any provider key
  already in the environment it inherits (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and so on),
  which OpenCode reads itself. The app keeps no copy and adds no key on the Mac. Signing in is
  OpenCode's own `opencode auth login`, run with the app's copy and handed over as a terminal
  step, as Copilot's is.
- **D4. The person's own OpenCode settings are left alone, and the app's agents run as the
  app needs.** The app writes nothing to `~/.config/opencode`, `~/.local/share/opencode` or a
  project's `opencode.json`. What it needs for its own agents is passed when it starts that
  agent, through OpenCode's inline configuration (`OPENCODE_CONFIG_CONTENT`), which OpenCode
  merges over the person's own. That covers turning off self-update, turning off sharing, and
  removing the tools that duplicate the app's. It holds for that agent only.
- **D5. Pinned, and never self-updated.** Each app version names one OpenCode version, the same
  on the Mac and on servers. OpenCode would otherwise update its own program, so the app's
  agents run with self-update off (D4). When a newer app names a newer version, the set-up page
  offers it as an update, and a running OpenCode agent keeps the program it started on until it
  ends.
- **D6. OpenCode's agents are the agent's modes; its providers' models are the model menu.**
  OpenCode reports its primary agents (normally `build` and `plan`) as ACP modes, and its models
  (every model of every signed-in provider) with their reasoning levels. The app shows them as
  it shows another runtime's modes and models, and remembers the last mode picked for OpenCode.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start an OpenCode agent on the Mac (Priority: P1)

The person has OpenCode signed in to at least one provider, or has never installed it. The first
time they open this version of the app, the set-up page lists OpenCode as **Not on this Mac**
with **Install**. It has not been offered before, so the page comes back once, even for someone
who dismissed it. One click, a few steps of progress on the row, and it is ticked. In the start
form, **OpenCode** is in the runtime list beside the others. They choose it and type a prompt.
Then OpenCode works like any other runtime: it replies as it thinks, calls tools, asks
permission where its settings say to, shows the diffs of the files it changes, reports usage
and cost, can be stopped mid-turn, and can be resumed later with its history.

**Why this priority**: It is the request. Without it the other stories have nothing to act on.

**Independent Test**: On a Mac with OpenCode signed in to one provider, and no app copy yet,
press **Install**, then start an OpenCode agent in a project and ask it to create a file and
run `ls`. The reply streams in, the tool calls show, the file appears in the changes, and a
later resume continues the conversation.

**Acceptance Scenarios**:

1. **Given** the start form, **When** the person opens the runtime list, **Then** OpenCode is listed with the other runtimes, and a new conversation can be started with it.
2. **Given** a Mac without the app's OpenCode, **When** the app starts, **Then** the set-up page lists OpenCode as not on this Mac with **Install**, once, even if the person dismissed the page before for other agents. The same row is in Settings ▸ Agents from then on.
3. **Given** OpenCode's row, **When** the person presses **Install**, **Then** the row shows each step while it works (downloading, checking, done) and a tick with where it is. A failure shows why, with **Retry** and **Open install page** *(default D1)*.
4. **Given** a running OpenCode agent, **When** a newer app installs a newer OpenCode, **Then** that agent is not interrupted and keeps its program until it ends *(default D5)*.
5. **Given** a running OpenCode agent, **When** it edits files, runs commands or asks permission, **Then** each shows in the conversation the way the same act from another runtime does. A permission ask offers OpenCode's three answers (allow once, always allow, reject) and can be answered on the Mac or the phone.
6. **Given** an OpenCode agent mid-turn, **When** the person stops it, **Then** the turn ends and the agent can be given a new prompt.
7. **Given** a stopped or parked OpenCode agent, **When** the person resumes it, **Then** it continues the same conversation with its history.
8. **Given** the modes menu for an OpenCode agent, **When** the person opens it, **Then** it lists OpenCode's own primary agents (normally **build** and **plan**). The one picked applies from the next turn, and is remembered for the next OpenCode agent *(default D6)*.
9. **Given** the model menu for an OpenCode agent, **When** the person opens it, **Then** it lists the models of every provider OpenCode is signed in to, with the provider named, and the reasoning levels where a model has them *(default D6)*.
10. **Given** a finished OpenCode turn, **When** it ends, **Then** its token use and its cost in dollars show as for other runtimes. Where OpenCode reports a cost of zero for a model with no per-token price (a subscription or a local model), no cost is shown rather than "$0.00".

---

### User Story 2 - Never the wrong `opencode` (Priority: P1)

The person already has an `opencode` on their PATH. It might be the archived Go program of the
same name, an SST release too old to have `acp`, or a current one from Homebrew or npm. None of
it matters to the app. OpenCode's row reads **Not on this Mac** until the app's own copy is
installed, and agents only ever start the app's copy. The person's own `opencode` is untouched,
and their terminal keeps running it.

**Why this priority**: This is the trap the spec exists to rule out. It ships with Story 1.

**Independent Test**: On a scratch root, put a fake `opencode` first on the search path that
records that it was run. OpenCode's row reads **Not on this Mac**. Install the app's copy, from
a local test release rather than GitHub, and start an OpenCode agent. The agent works, and the
fake recorded nothing.

**Acceptance Scenarios**:

1. **Given** an `opencode` of the person's own on the PATH and no app copy, **When** the set-up page is shown, **Then** OpenCode reads **Not on this Mac**, and no agent is started with the person's copy *(default D1)*.
2. **Given** the app's copy installed and another `opencode` earlier on the PATH, **When** an OpenCode agent starts, or the sign-in sheet hands over its command, **Then** it is the app's copy that runs, by its full path.
3. **Given** an `opencode` of the person's own, **When** the app installs, updates or removes its copy, **Then** the person's is not changed, moved or removed.
4. **Given** the app's copy fails its check at start (missing, altered, or not answering ACP's opening handshake as OpenCode), **When** an agent starts, **Then** the agent ends within the app's usual start-up limit with a sentence saying so, and the row offers **Install** again. It never waits forever and never falls back to a copy on the PATH.

---

### User Story 3 - Sign OpenCode in on the Mac (Priority: P2)

The person starts an OpenCode agent with no provider signed in, or picks a model whose provider
is not signed in. They do not get a silent failure or an empty reply. The agent says OpenCode
needs a provider signed in, and names that provider when OpenCode names it. The runtime menu
shows **Needs signing in** beside OpenCode, and **Sign in, sign out, providers…** opens the same
sheet the other runtimes use. There, OpenCode's sign-in is its own `opencode auth login`, run
with the app's copy and handed over with **Open Terminal** and **Copy**, as for Copilot. That
command lists OpenCode's providers and runs each one's own browser, device-code or key step.

**Why this priority**: Many people trying OpenCode here will have installed it from the set-up
page a moment ago, with nothing signed in.

**Independent Test**: With OpenCode's sign-in file absent from a scratch home, start an OpenCode
agent and prompt it. The turn ends saying a provider needs signing in, and the sheet offers the
command. Run it in Terminal, sign in to one provider, and the next turn works.

**Acceptance Scenarios**:

1. **Given** OpenCode with no usable provider, **When** a turn is refused for it, **Then** the agent says OpenCode needs signing in, naming the provider if OpenCode named it. It never waits forever or shows only "stopped answering".
2. **Given** the sign-in sheet for OpenCode, **When** it opens, **Then** it shows the app's copy's `auth login` command with **Open Terminal** and **Copy**, and which providers OpenCode is signed in to, if the app can tell *(default D3)*.
3. **Given** OpenCode's ACP sign-in step, **When** the app would call it, **Then** the app does not treat it as signing anyone in. OpenCode's `authenticate` accepts the call and does nothing, so a "signed in" state never comes from it.
4. **Given** the sheet, **When** the person looks for **Sign out**, **Then** there is none, as for Cursor. The sheet names `auth logout` for signing a provider out in Terminal.
5. **Given** a provider key already in the environment the app started with, **When** an OpenCode agent starts on the Mac, **Then** OpenCode can use it, and the app neither adds nor removes such a key *(default D3)*.

---

### User Story 4 - The app's own tools and scoping (Priority: P2)

An OpenCode agent works inside the app the way a Claude agent does. It has the app's tools: it
ends its turn with a report, asks questions, leases resources, waits for events, starts helpers,
and starts and runs workflows. OpenCode's own tools that duplicate the app's are taken away for
the conversations the app starts. Where one cannot be taken away, it is named as residue.
OpenCode's question tool is off over ACP, so when an OpenCode agent needs an answer it uses the
app's question tool. If it ends its turn with a question in plain words instead, the agent shows
**Waiting on your answer**, as Grok does.

**Why this priority**: Without it OpenCode runs, but outside the app's rules. The runtime policy
table must cover every runtime in the catalog, or a test fails, so this story has to ship
alongside Story 1 before OpenCode is offered.

**Independent Test**: Start an OpenCode agent and ask it to list the tools it has. The app's
tools are listed and the removed ones are not. Ask it to end its turn with a report, to lease a
resource and to ask a question. Each arrives in the app as it does for Claude.

**Acceptance Scenarios**:

1. **Given** an OpenCode agent, **When** it starts, **Then** it is given the app's tools (OpenCode takes the app's tool server as ACP passes it) and the same briefing as other runtimes.
2. **Given** an OpenCode agent, **When** it ends a turn, **Then** it reports the turn's outcome through the app's tool, as Claude does.
3. **Given** OpenCode's own tools that overlap with the app's (its `task` tool, which starts sub-agents the app never sees, and its to-do list), **When** the app starts an OpenCode agent, **Then** they are removed for that agent. Where one cannot be removed, it is named as residue in the policy and in the briefing.
4. **Given** OpenCode's sharing (which publishes a conversation to a public web page), **When** the app starts an OpenCode agent, **Then** sharing is turned off for that agent, whatever the person's own setting *(default D4)*.
5. **Given** an OpenCode agent that needs an answer mid-turn, **When** it asks, **Then** the person sees a question card through the app's tool, or, if it ends its turn with the question instead, the agent shows **Waiting on your answer** with the question.
6. **Given** OpenCode in Terminal, the person's own or the app's, **When** the person uses it there, **Then** it has every tool and setting it always had, and the app has changed none of them *(default D4)*.
7. **Given** the person's own OpenCode setup (their MCP servers, custom agents, commands and `AGENTS.md` rules), **When** an OpenCode agent starts in the app on the Mac, **Then** OpenCode loads them as it would in Terminal, except for the tools the app removed.

---

### User Story 5 - OpenCode on servers (Priority: P3)

The person has a bare Linux server added as in 043, and OpenCode on the Mac, signed in or not.
When they start an OpenCode agent in a project on that server, the server installs OpenCode's
pinned Linux program the first time, with its progress in the set-up checklist. The agent is
then lent the providers OpenCode is signed in to on the Mac, for that run, and offers their
models beside OpenCode Zen's free ones. Nothing of the Mac's sign-in is written to the server's
disk. There is nothing to set up in Settings *(D7)*.

**Why this priority**: It extends 043 to OpenCode. That matters for the ephemeral servers 043
is about, but the Mac comes first.

**Independent Test**: With OpenCode on the Mac signed in to one provider by key, and a Linux
server with nothing on it, start an OpenCode agent in a server project, pick that provider's
model, and ask it to run `uname -a`. The reply comes back from that model. Afterwards, a search
of the server's disk finds neither the key nor an `auth.json` of the Mac's.

**Acceptance Scenarios**:

1. **Given** a server without OpenCode, **When** OpenCode is first needed there, **Then** the server installs the pinned Linux program for its architecture and C library, checks it against the app's checksum, and shows its progress. A failed install names its cause and leaves nothing half-installed *(D2, default D5)*.
2. **Given** an OpenCode agent starting on a server, **When** it starts, **Then** the Mac's lendable OpenCode sign-ins reach that run only, in its environment. They are not written to the server's disk, any log or any transcript, and are not sent for any other runtime *(D7)*.
3. **Given** an OpenCode agent on a server, **When** the person opens its model menu, **Then** it lists OpenCode Zen's free models, the lent providers' models, and any the server's own OpenCode sign-in adds.
4. **Given** a server marked "use this server's own sign-in only" (043), **When** an OpenCode agent starts there, **Then** nothing is lent, and OpenCode's own sign-in on the server is used.
5. **Given** a Mac sign-in that is not lent (a rotating account sign-in), **When** an OpenCode agent starts on a server, **Then** its provider's models are not offered there, and the sign-in sheet says which sign-ins stay on the Mac and why *(D7 default)*.
6. **Given** a lent key the provider refuses, **When** a turn uses it, **Then** the turn ends saying the provider refused the Mac's sign-in, and names `opencode auth login` on the Mac to fix it.

---

### Everywhere a runtime is chosen

OpenCode is offered wherever another runtime is: a workflow's steps, the phone's and iPad's start
forms (which start agents through the Mac), the runtime menu above the prompt, and `start_agent`
from another agent. On a server project it is offered when it is installed there, or can be
installed there (User Story 5).

### Edge Cases

- **An `opencode` of the person's own.** The archived Go one, an old SST one, or a current one from the vendor's script, Homebrew or npm: it is never used or changed, and it never makes the row read as installed (Story 2).
- **Install fails.** Offline, GitHub unreachable or rate-limited, a download that does not match its checksum, or no room. The row says which, in 048's wording, with **Retry** and **Open install page**. Nothing half-installed is ever used.
- **An Intel Mac without AVX2.** It gets the `-baseline` build. The plan decides how the app tells which build a Mac needs. An unsupported Mac shows OpenCode as unavailable, with the reason, and does not offer it in the start form.
- **Gatekeeper.** The app's copy is downloaded by the app, not a browser. The plan records whether the release program runs without a prompt.
- **Self-update.** OpenCode replaces its own program if allowed to. The app's agents run with it off (D5), so the app's copy moves only when the app moves it. A running agent keeps its process through an update.
- **A model the provider no longer serves, or a provider signed out mid-session.** The turn ends with OpenCode's reason in a sentence, and the model menu is refreshed at the next start.
- **Rate limits and quota.** A provider's rate limit or exhausted quota ends the turn with the reason in a sentence, not as a crash.
- **No provider at all, but a free model.** If OpenCode offers a model that needs no sign-in, a turn with it works, and the agent does not claim to need signing in. The plan measures whether any such model exists.
- **`/undo` and `/redo`.** OpenCode's docs say these slash commands do not work over ACP. The app does not offer them for OpenCode.
- **Pictures.** OpenCode says it takes pictures over ACP, so a picture attached for an OpenCode agent goes as a picture. The model chosen may still refuse it, and that refusal shows in OpenCode's own words.
- **A project's own `opencode.json`.** It loads in the app's agents as in Terminal. The app's inline settings are merged over it and win only for the keys the app sets (D4).
- **A server key the provider refuses.** The agent stops with a sentence saying the key was refused, with a way to replace it, and this reads differently from any other failure (043 FR-016).
- **A key in the server's environment.** The lent key replaces any key for the same provider in the server's environment for that run (043 D1). Other providers' keys there are OpenCode's business.
- **The Mac's sign-in is never lent.** `auth.json` can hold browser sign-ins (a ChatGPT or Copilot account). They are refresh tokens that rotate, as 047 D4 records for Codex. Nothing in it is copied to a server.

## Requirements *(mandatory)*

### Functional Requirements

**Starting OpenCode on the Mac**

- **FR-001**: The app MUST list OpenCode among the runtimes it can start, everywhere a runtime is chosen: the Mac's start form and runtime menu, the phone and iPad start forms, workflow steps, and `start_agent`. It MUST start it as `<app's copy> acp`.
- **FR-002**: OpenCode MUST have a row on 048's set-up page (start-up sheet, Settings ▸ Agents, empty project list), offered once to people who already dismissed the page. Its **Install** puts the pinned OpenCode release program for this Mac in the app's own folder, checked against the SHA-256 the app carries. OpenCode MUST need nothing installed beforehand *(D1)*.
- **FR-003**: Agents MUST run only the app's copy of OpenCode, by its full path. The app MUST NOT look `opencode` up on the PATH to start it. An `opencode` the person installed MUST NOT be used, changed or removed, and MUST NOT make OpenCode's row read as installed *(D1)*.
- **FR-004**: The app MUST NOT run OpenCode's install script or install OpenCode with npm or Homebrew, on the Mac or on a server.
- **FR-005**: Starting an OpenCode agent when the app's copy is not installed, still installing, failed to install, or fails its check MUST say which, offer the row's action, and never start and then hang.
- **FR-006**: OpenCode MUST be pinned: each app version names one OpenCode version for the Mac and servers. An OpenCode agent MUST run with self-update off, and MUST keep the program it started with until it ends *(default D5)*.
- **FR-007**: An OpenCode agent MUST show replies, tool calls, permission asks, file changes, stop and resume the way the app shows them for other runtimes, limited only by what OpenCode reports over ACP.
- **FR-008**: Token use MUST be shown where OpenCode reports it. Cost MUST be shown where OpenCode reports a non-zero cost, and left out rather than shown as zero where it does not.
- **FR-009**: OpenCode's primary agents MUST show as the agent's modes, and its models, labelled by provider and with reasoning levels, as the model menu, both as OpenCode reports them. The last mode picked MUST be remembered for OpenCode, and helpers MUST inherit it as they do for other runtimes *(default D6)*.
- **FR-010**: What OpenCode can do in the app (pictures, resume, modes, models, sign-in) MUST follow what it says about itself when it starts, not a list kept by the app.

**Signing in on the Mac**

- **FR-011**: A turn refused because a provider is not signed in (ACP's "authentication required") MUST end with a sentence saying OpenCode needs signing in, naming the provider when OpenCode names it, with a way to open the sign-in sheet. It MUST NOT fail silently or wait forever.
- **FR-012**: The sign-in sheet MUST offer the app's copy's `auth login` as a terminal step, with **Open Terminal** and **Copy**. It MUST NOT offer an in-app sign-in or sign-out that OpenCode cannot carry out over ACP.
- **FR-013**: The app MUST NOT report OpenCode as signed in on the strength of OpenCode's ACP `authenticate` answer alone.
- **FR-014**: On the Mac, the app MUST NOT keep a copy of OpenCode's sign-in, and MUST NOT add or remove provider keys in an OpenCode agent's environment. The app MUST NOT pass `OPENCODE_AUTH_CONTENT` to agents on the Mac *(default D3)*.

**The app's tools and scoping**

- **FR-015**: An OpenCode agent MUST be given the app's tools and the same briefing as other runtimes.
- **FR-016**: The runtime tool policy MUST have an entry for OpenCode. It removes OpenCode's tools that duplicate the app's (at least `task`, which starts sub-agents, and its to-do list) and names as residue any it cannot remove. The policy MUST cover every runtime in the catalog, and a test MUST say so.
- **FR-017**: Sharing MUST be off for every OpenCode agent the app starts, on the Mac and on servers.
- **FR-018**: An OpenCode agent's mid-turn question MUST reach the person through the app's question tool, or otherwise as **Waiting on your answer** with the question.
- **FR-019**: The app MUST NOT write to `~/.config/opencode`, `~/.local/share/opencode`, `~/.opencode` or a project's OpenCode files. Everything it sets for its own agents MUST be passed when it starts that agent *(default D4)*.

**OpenCode on servers**

- **FR-020**: Settings' runtime credentials MUST NOT gain an OpenCode entry. A server's OpenCode MUST be lent the Mac's own OpenCode sign-in instead *(D7)*.
- **FR-021**: A server MUST install OpenCode's pinned Linux program on demand, from OpenCode's GitHub releases, for the server's architecture and C library (glibc or musl), checked against the checksum the app carries, with progress in the set-up checklist. An incomplete install MUST never be used *(D2, default D5)*.
- **FR-022**: The Mac's OpenCode sign-in MUST reach a server only as part of starting OpenCode there, for that run, in the run's environment (`OPENCODE_AUTH_CONTENT`). It MUST NOT be written to the server's disk, any log, transcript or crash report, or sent for any other runtime.
- **FR-023**: Only sign-ins that do not rotate (provider keys) MUST be lent until a rotating one is measured not to break the Mac's copy. The app MUST NOT otherwise change the Mac's `auth.json` *(D7 default)*.
- **FR-024**: 043's rules for servers MUST hold for OpenCode as they do for Claude: a server's "own sign-in only" mark, a refused key shown as its own failure, and a rebuilt server set up again on confirmation.

**Failures**

- **FR-025**: OpenCode not installed (or still installing, or failed), a copy that fails its check, an unsupported Mac, an unanswered start, a provider not signed in, a model no longer served, a rate limit or quota, and a refused server key MUST each end with a sentence naming the cause, never an endless wait or "stopped answering".

### Key Entities

- **OpenCode runtime**: an entry in the app's runtime list: its name, how it is started (the app's own copy, `acp`), how it is installed (a pinned release program, from the set-up page), and what it says about itself when it starts.
- **OpenCode toolset**: the pinned release program for one platform (macOS arm64 or x64 or x64-baseline; Linux x64 or arm64, glibc or musl, with x64-baseline builds), with its version and SHA-256. On the Mac it is installed from the set-up page into the app's own folder. On a server it is one of 043's installed tools, beside Claude's, replaced as a whole.
- **OpenCode tool policy**: which of OpenCode's tools are removed for the app's agents, which remain as residue and why, the per-agent settings the app passes (self-update off, sharing off), and how its questions reach the person.
- **OpenCode sign-in (Mac)**: OpenCode's own list of signed-in providers in the person's home. On the Mac, read by OpenCode itself. For a server run, the app reads it and lends its non-rotating entries in that run's environment, and never changes it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Mac with nothing of OpenCode's, a person goes from pressing **Install** on the set-up page to an OpenCode agent's first reply within 3 minutes, counting one provider's sign-in, having typed no command except the one the sheet hands them.
- **SC-002**: With OpenCode installed and signed in, an OpenCode start reaches its first reply no more than 5 seconds later than a Claude start on the same Mac, using the same underlying model where possible.
- **SC-003**: With the archived Go `opencode`, or any other program of that name, first on the PATH, 10 of 10 OpenCode starts run the app's copy, and that other program is never run.
- **SC-004**: Every failure in the edge cases above shows as a sentence naming its cause. None shows as an endless wait or as "stopped answering".
- **SC-005**: After a day of OpenCode agents in the app, the app has written nothing to the person's `~/.config/opencode` or `~/.local/share/opencode` (OpenCode's own first-run files aside, research R4), `auth.json` is byte for byte what it was, and no conversation has been shared.
- **SC-006**: From a bare Linux server, a person with OpenCode signed in on the Mac gets an OpenCode agent's first reply within 5 minutes, having run no command on the server. Afterwards, a search of the server's disk and the Mac's logs finds the key in neither, and finds no `auth.json` of the Mac's on the server.
- **SC-007**: An OpenCode agent's turns end with the app's outcome report in at least 9 of 10 turns, as measured for the other runtimes that have the app's tools.

## Docs *(mandatory)*

- `docs/reference/runtimes.md` — change: the runtime count, plus an OpenCode row: installed by the app from the set-up page, only the app's copy is used, pictures, sign-in through `opencode auth login`, modes are OpenCode's agents, models from every signed-in provider, app tools, residue, and why an `opencode` already on the PATH is ignored.
- `docs/how-to/sign-a-runtime-in.md` — change: name OpenCode, and describe `auth login` and its providers.
- `docs/how-to/add-a-linux-server.md` — change: OpenCode installs on a server as Claude does, and borrows the Mac's OpenCode sign-in per run; which sign-ins stay on the Mac.
- `docs/explanation/scoped-tools.md` — change: add OpenCode's removed tools, its residue, and why sharing is off.

## Assumptions

- **Sources.** The facts in this spec come from the vendor's own docs and source, read on 2026-09-25. Nothing was installed or run:
  - ACP: <https://opencode.ai/docs/acp/> (the command is `opencode acp`, and `/undo` and `/redo` are unsupported).
  - Install: <https://opencode.ai/docs/> and the install script itself, <https://opencode.ai/install>, which redirects to <https://raw.githubusercontent.com/anomalyco/opencode/refs/heads/dev/install>. The script's details (`INSTALL_DIR=$HOME/.opencode/bin`, no checksum check, the shell files it edits) are why D1 does not use it.
  - Config and precedence, including `OPENCODE_CONFIG_CONTENT`, `autoupdate`, `share`, `tools` and `permission`: <https://opencode.ai/docs/config/>.
  - Providers, `/connect`, `~/.local/share/opencode/auth.json`, environment keys and the browser and device-code sign-ins: <https://opencode.ai/docs/providers/>.
  - ACP implementation, from `anomalyco/opencode` `dev`:
    - `packages/opencode/src/acp/service.ts`: `initialize` advertises `loadSession`, image and embedded-context prompts, HTTP and SSE MCP, and session close, fork, list and resume. It offers one auth method, "Login with opencode" ("Run `opencode auth login` in the terminal"), carrying a `terminal-auth` command only when the client says it supports that. `authenticate` is a no-op. Primary agents become modes, with default `build`.
    - `packages/opencode/src/acp/error.ts`: a missing provider is ACP's `-32000` "provider authentication required", with `providerId`.
    - `packages/opencode/src/acp/permission.ts`: permission options are allow once, always allow and reject.
    - `packages/opencode/src/acp/usage.ts`: `usage_update` carries context used and size, and the session's cost in USD.
    - `packages/opencode/src/acp/config-option.ts`: config options for model, effort and mode.
    - `packages/opencode/src/tool/registry.ts`: the `question` tool is enabled only for the `app`, `cli` and `desktop` clients, so it is off over ACP.
  - Releases: <https://github.com/anomalyco/opencode/releases>. v1.18.32 (2026-09-21) has `opencode-darwin-arm64.zip`, `opencode-darwin-x64.zip`, `opencode-darwin-x64-baseline.zip` and `opencode-linux-{x64,arm64}[-baseline][-musl].tar.gz`, each with a SHA-256 digest in the release's metadata, beside the separate `opencode-desktop-*` app.
  - The name collision: <https://github.com/opencode-ai/opencode> (archived; continues as <https://github.com/charmbracelet/crush>).
- **Open questions that need a real binary**, measured in planning with the app's copy on a scratch home. Never the real home, and never the vendor's script (memory "Vendor scripts touch the real home"):
  - Does the app today tell a runtime it supports `terminal-auth`? The app reads Copilot's `_meta.terminal-auth` from an auth method, but OpenCode adds that only when the client advertises `clientCapabilities._meta["terminal-auth"]`. Without it, the sheet builds the command from the app's copy's path.
  - How exactly the "not signed in" failure arrives: on `session/new` or on the first `session/prompt`.
  - Does OpenCode need any provider at all before `session/new` succeeds, and is there a model that works signed out?
  - Which tool ids `tools` and `permission` in inline config can remove (`task`, `todowrite`, the plan tools), and whether any come back through a custom agent.
  - Whether `autoupdate: false` in inline config is enough to stop self-update under ACP, and whether a self-update would try to replace the app's copy.
  - Whether the macOS release program is signed and notarised, so it runs without a Gatekeeper prompt when the app downloads it.
  - How a sign-in reaches OpenCode for one run: answered 2026-09-28, `OPENCODE_AUTH_CONTENT` (research R7).
- **Builds on 048** (the set-up page and the Mac toolset install, merged `ee64697`). OpenCode is a pinned toolset like Claude's, but a single program with no Node. The row, progress, failure sentences and "offered once" rule are 048's.
- **Builds on 043** (runtime credentials, server toolsets, "own sign-in only"), which is merged. It extends 043's D3 "Claude first" to OpenCode, as 046 and 047 do for Gemini and Codex., lending the Mac's own sign-in as 056 does for Claude.
- **Beside 046 and 047.** All three add a runtime, a policy entry, a toolset and docs rows. Whichever merges last takes the others' rows, and the runtime count in the docs is written from the catalog at that point.
- **The phone and iPad** start OpenCode agents through the Mac. Nothing OpenCode-specific runs on them.
