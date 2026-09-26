# Feature Specification: Goose as a Runtime

**Feature Branch**: `agents/write-spec-adding-goose`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Add Goose (Block's open-source agent) as a built-in runtime alongside
Claude, Grok, Copilot and Cursor."

## Why this feature exists

The app starts four runtimes: Claude, Grok, Copilot and Cursor. 046 adds Gemini and 047 adds
Codex. Goose is the open-source agent Block started. It now lives at `aaif-goose/goose`, and its
docs are at goose-docs.ai. Goose is different from the others: it has no model and no account of
its own. It drives whichever model provider the person points it at, such as Anthropic, OpenAI,
Google, OpenRouter, a local Ollama, a company gateway, or even another agent's CLI. People who use
Goose chose it for that freedom. Today they run it in a terminal, or in Goose's own desktop app,
next to this one, and none of that work shows up in this app's lists, on the phone, in workflows
or in leases.

Goose speaks the agent protocol (ACP) itself, with no adapter: `goose acp` is one of its own
subcommands. So Goose can be added as another runtime, not built as a special case. The work is in
the parts that differ between runtimes. These are: making sure the `goose` the app starts is
really Goose, how the person picks a provider and a model, how Goose says it has none, which of
its tools overlap with the app's, and how it asks before acting.

**This feature makes Goose a runtime like the others**, on the Mac and on servers. On the Mac,
the person picks Goose's provider and model in Goose's own way, and the app shows and switches
them per agent. On servers, Goose signs in with one provider's key lent from the Mac.

### The `goose` trap

`RuntimeCatalog`'s header records that Cursor's docs call it `agent`, and that `agent` on this
Mac is Grok. Goose has the same kind of trap, and it is worse, because it is common:

- **Homebrew's `goose` is not this Goose.** `brew install goose` installs *pressly/goose*, a
  database-migration tool, as `/opt/homebrew/bin/goose` (Homebrew formula `goose`, "Go Language's
  command-line interface for database migrations", 3.28.0). Block's Goose is the formula
  `block-goose-cli`, which also installs a binary called `goose`, and Homebrew marks the two as
  conflicting: "both install `goose` binaries". Anyone who works with Go databases may have the
  wrong one.
- **The search order finds the wrong one first.** `LoginShellPath.fallbacks` searches
  `/opt/homebrew/bin` and `/usr/local/bin` before `~/.local/bin`, which is where Goose's own
  installer puts it. The person's login PATH usually has the same order. So a Mac with both finds
  the migration tool.
- **The migration tool fails without a word.** `goose acp` sent to pressly/goose is an unknown
  command. It prints its usage and exits. Unless the app checks, that shows as "stopped
  answering".
- **Goose Desktop is not the CLI.** The `block-goose` cask installs `/Applications/Goose.app`.
  Having it installed does not put a `goose` command on the PATH, and the app does not start
  anything inside it.

So "a `goose` was found" never counts as "Goose is installed". The spec rules this out in two
ways: agents run only a Goose the app installed (D1), and any `goose` the app looks at must say
it is Goose before the app treats it as installed (FR-003).

## Clarifications

### Session 2026-09-25

- Q: How should the app get Goose onto the Mac, given that Homebrew's `goose` is a migration tool? → A: The app's own pinned copy, installed from the set-up page. The person's own `goose` is never used (D1).
- Q: Should this spec cover Goose on Linux servers? → A: Yes. Install Goose on the server as 043 does for Claude, and lend one provider's key per run from Settings (D2).
- Q: Which approval mode should a Goose agent start in? → A: The person's own Goose mode (usually `auto`), shown clearly, and then the last mode picked in the app (D5).

## Defaults taken *(Alex to confirm or overturn)*

Alex settled D1, D2 and D5 on 2026-09-25. The rest are defaults so that the spec is complete,
and each is marked *(default Dn)* where it is used.

- **D1. The app's own copy only, installed from the set-up page.** Goose ships as a single
  native program for each platform (macOS Apple silicon and Intel, Linux x86-64 and ARM64), with
  no Node or other runtime beside it. So Goose is a row on 048's set-up page (**Install your
  agents** at start-up, Settings ▸ Agents, and under an empty project list). **Install** puts a
  pinned Goose release, checked against a checksum the app carries, in the app's own folder,
  which is the pattern Alex settled for Gemini (046 D1) and Codex (047 D3). A `goose` of the
  person's own is never used, changed or removed, even when it is really Goose. This makes the
  migration-tool trap impossible rather than merely detected. *(Settled by Alex, 2026-09-25,
  over running Goose's own `download_cli.sh` into `~/.local/bin` like Grok, Copilot and Cursor.)*
- **D1a. If Goose's own installer is ever run, it runs non-interactively.** Goose's installer
  runs `goose configure` at the end and asks whether to edit the shell's rc files, reading the
  answers from `/dev/tty`, unless `CONFIGURE=false`. D1 and D2 do not run it: both fetch the
  pinned release directly. If a later change ever runs it, it runs with `CONFIGURE=false`, never
  edits `~/.zshrc` or the like, and checks that the result is Goose (FR-003).
- **D2. On the Mac and on servers, with one provider's key lent from the Mac.** Servers get
  Goose the way 043 gives them Claude: a pinned Linux release installed on demand. Its
  credential is a *Goose server credential* in Settings ▸ Runtime credentials: one provider,
  that provider's API key, and optionally a model. It is lent to each server run as Goose's own
  environment (the provider and model as `GOOSE_PROVIDER` and `GOOSE_MODEL`, and the key under
  the provider's own variable, for example `ANTHROPIC_API_KEY`), and never written to the
  server's disk. The Mac's own Goose configuration and Keychain keys are never copied to a
  server. *(Settled by Alex, 2026-09-25.)*
- **D2a. Key-based providers only, for servers.** The server credential offers the providers
  whose sign-in is a single API key: Anthropic, OpenAI, Google (Gemini) and OpenRouter. Providers
  that sign in through a browser (ChatGPT, GitHub Copilot, Tetrate), cloud accounts (Bedrock,
  Vertex, Databricks, Azure) and local ones (Ollama) are not offered for servers in this version.
  A server's own Goose configuration is still used on a server marked "use this server's own
  sign-in only" (043).
- **D3. The provider is Goose's own setting.** The person chooses a provider and enters its key
  or signs in with `goose configure`, Goose's own interactive set-up. It writes
  `~/.config/goose/config.yaml` and keeps keys in the Mac's Keychain. On the Mac, the app never
  asks for a provider key itself and never keeps one (servers are D2). The app's sign-in sheet hands over the exact command
  for the app's copy, with **Open Terminal** and **Copy**, as it does for Copilot.
- **D4. Provider, model and thinking effort per agent, in the app.** Goose reports a **Provider**
  menu, a **Model** menu and, where the model has one, a **Thinking effort** menu for each
  session. The app shows them, and a change applies to that agent only. The app does not write
  the person's default provider or model. If a Goose switch turns out to change the person's
  saved default as well, the plan records that and the app does not offer the switch.
- **D5. Goose's approval modes are the agent's modes, and a Goose agent starts in the person's
  own Goose mode.** Goose has four modes: `auto` (approves every tool call itself, and is Goose's
  default), `approve` (asks before every tool call), `smart_approve` (asks only for sensitive
  ones) and `chat` (no tools). They show in the modes menu. A Goose agent starts in whatever mode
  the person's Goose is set to, which is `auto` for a Goose never configured otherwise. After
  that, the app remembers the last mode picked for Goose, and helpers inherit it, as for other
  runtimes. On a server, with no Goose configuration there, that means `auto` until a mode is
  picked. *(Settled by Alex, 2026-09-25, over starting the first agent in `smart_approve` or
  `approve`.)*
- **D6. The person's own Goose settings are left alone.** The app does not edit
  `~/.config/goose/config.yaml`, `secrets.yaml`, Goose's Keychain items, its custom providers,
  its recipes or its saved sessions. It does not point Goose at a config folder of its own
  either, because that would hide the provider the person set up. Anything the app sets for its
  own agents (its tools, which of Goose's tools are removed, the starting mode) is passed when it
  starts that agent, and holds for that agent only.
- **D7. Pinned.** Each app version names one Goose release. When a newer app names a newer one,
  the set-up page offers it as an update, and a running Goose agent keeps the build it started
  on until it ends (047's groundwork).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a Goose agent on the Mac (Priority: P1)

The person already uses Goose with, say, their Anthropic key, or has never installed it. The
first time they open this version of the app, the set-up page lists Goose as **Not on this Mac**
with **Install**. It has not been offered before, so the page comes back once, even for someone
who dismissed it earlier. One click, a few steps of progress on the row, and it is ticked. In the
start form, **Goose** is in the runtime list beside the others. They choose it and type a prompt.
Then Goose works like any other runtime: it replies as it thinks, calls tools, asks permission
where its mode says to, shows the diffs of the files it changes, reports usage and cost as far as
Goose says them, can be stopped mid-turn, and can be resumed later with its history.

**Why this priority**: It is the request. Without it the other stories have nothing to act on.

**Independent Test**: On a Mac with a configured Goose provider (or a fresh one configured
through Story 2), and with pressly/goose deliberately on the PATH, install Goose from the set-up
page. Start a Goose agent in a project and ask it to create a file and run `ls`. The reply
streams in, the tool calls show, the file appears in the changes, and a later resume continues
the conversation. The migration tool was never started.

**Acceptance Scenarios**:

1. **Given** the start form, **When** the person opens the runtime list, **Then** Goose is listed with the other runtimes, and a new conversation can be started with it.
2. **Given** a Mac without the app's Goose, **When** the app starts, **Then** the set-up page lists Goose as not on this Mac with **Install**, once, even if the person dismissed the page before for other agents. The same row is in Settings ▸ Agents from then on *(default D1)*.
3. **Given** Goose's row, **When** the person presses **Install**, **Then** the row shows each step while it works, and a tick with where it is when done. A failure shows why, with **Retry** and **Open install page** *(default D1)*.
4. **Given** pressly/goose, a Goose of the person's own, or both on the PATH, and no app copy, **When** the set-up page is shown, **Then** Goose still reads **Not on this Mac**, and no agent is ever started with either *(default D1)*.
5. **Given** a running Goose agent, **When** it edits files, runs commands or asks permission, **Then** each shows in the conversation the way the same act from another runtime does, and a permission ask can be answered on the Mac or the phone.
6. **Given** a Goose agent mid-turn, **When** the person stops it, **Then** the turn ends and the agent can be given a new prompt.
7. **Given** a stopped or parked Goose agent, **When** the person resumes it, **Then** it continues the same conversation with its history.
8. **Given** a running Goose agent, **When** a newer Goose is installed, **Then** that agent is not interrupted and keeps its build until it ends *(default D7)*.
9. **Given** a Goose turn that reports tokens or cost, **When** it ends, **Then** usage shows as for other runtimes. Where Goose reports nothing, nothing is shown, never a zero.

---

### User Story 2 - Choose Goose's provider (Priority: P1)

The person installs Goose for the first time and has never configured it. They start a Goose
agent. They do not get a silent failure, an empty reply or "stopped answering". The runtime menu
says **Needs signing in** beside Goose. **Sign in, sign out, providers…** opens the same sheet
the other runtimes use. For Goose, it says that Goose uses a model provider of the person's
choosing, and hands over the exact command that sets one up, `goose configure` run with the app's
copy, with **Open Terminal** and **Copy**. The person picks a provider (for example Anthropic,
OpenAI, Google, OpenRouter, Ollama or GitHub Copilot), pastes a key or signs in in the browser
where that provider offers it, and picks a model. Back in the app, the sheet reads **Signed in and
ready**, and the next Goose agent starts.

**Why this priority**: Every fresh Goose needs this before its first reply. Goose has no default
model to fall back on, so without this story Story 1 fails for every new user. It ships with
Story 1.

**Independent Test**: With a Goose that has no provider configured (a scratch home with no
`~/.config/goose`), start a Goose agent: the app says Goose needs a provider and offers the sheet.
Run the handed-over command, pick a provider, and enter a key. A new turn works, and `goose` in
Terminal (if the person has their own) uses the same provider.

**Acceptance Scenarios**:

1. **Given** Goose with no provider configured, **When** the person starts a Goose agent, **Then** the agent says Goose needs a provider set up, with a way to do it, and never waits forever or shows only "stopped answering" *(default D3)*.
2. **Given** the sign-in sheet for Goose, **When** it opens, **Then** it shows where Goose stands (**Signed in and ready**, **Installed, and needs signing in**, or **Not asked yet**), says in a sentence that Goose uses a provider of the person's choosing, and offers Goose's own set-up command with **Open Terminal** and **Copy** *(default D3)*.
3. **Given** the handed-over command, **When** the person reads it, **Then** it names the app's copy of Goose by its full path, so it works on a Mac with no `goose` on the PATH, and never runs the migration tool.
4. **Given** a provider configured with `goose configure`, **When** a Goose agent starts, **Then** it uses that provider and model, the same ones Goose uses in Terminal, and the app has written no setting of its own *(default D6)*.
5. **Given** a provider key that has expired or been revoked, **When** a Goose turn is refused for it, **Then** the turn ends with a sentence saying Goose's provider refused the sign-in, naming the provider if Goose names it, with the sheet one click away.
6. **Given** Goose signed in, **When** the person looks for a sign-out button, **Then** there is none, as for Cursor. Goose's providers are changed in Goose's own set-up, which the sheet points to.
7. **Given** a provider that has run out of credits, or a rate limit, **When** a Goose turn is refused for it, **Then** the turn ends with a sentence saying which, and the agent can be prompted again later.

---

### User Story 3 - Switch provider, model and mode for one agent (Priority: P2)

A Goose agent is running on the person's default provider. They open the model menu above the
prompt and see Goose's **Provider**, **Model** and, for models that have one, **Thinking effort**,
as Goose reports them. They switch this agent from one provider's model to another's for a harder
task. The next turn uses the new model. Their other Goose agents, and Goose in Terminal, keep the
default. The modes menu shows Goose's four modes, with Goose's own description under each.

**Why this priority**: Choosing the model per task is why people use Goose. But an agent on the
default provider is already useful, so this follows the P1 stories.

**Independent Test**: With two providers configured in Goose, start a Goose agent, switch its
provider and model from the menu, and ask it which model it is. The reply comes from the new
model. Start a second Goose agent: it is on the default. `~/.config/goose/config.yaml` is
unchanged.

**Acceptance Scenarios**:

1. **Given** a Goose agent, **When** the person opens the model menu, **Then** it lists Goose's providers, the models of the current provider, and thinking effort where the model has it, as Goose reports them *(default D4)*.
2. **Given** a switch of provider or model, **When** the next turn runs, **Then** it uses the new choice, and the model shown for the agent is the one Goose reports as in use.
3. **Given** a switch in one agent, **When** another Goose agent starts, or Goose runs in Terminal, **Then** it uses the person's default, and the person's Goose settings are byte for byte unchanged *(default D4, D6)*.
4. **Given** a provider in the menu that is not configured, **When** the person picks it, **Then** the app says it needs setting up in Goose and offers the sheet. The agent keeps its current provider, and nothing fails silently.
5. **Given** the modes menu for a Goose agent, **When** the person opens it, **Then** it lists `auto`, `approve`, `smart_approve` and `chat`, each with Goose's description. The one picked applies from the next action and is remembered for the next Goose agent *(default D5)*.
6. **Given** a Goose agent in `auto` mode, **When** the person looks at it, **Then** the mode is visible where modes are shown, so that nobody takes a Goose that approves its own tool calls for one that asks *(default D5)*.

---

### User Story 4 - The app's own tools and scoping (Priority: P2)

A Goose agent works inside the app the way a Claude agent does. It has the app's tools: it ends
its turn with a report, asks questions, leases resources, waits for events, starts helpers, and
starts and runs workflows. Goose's own tools that duplicate the app's are taken away for the
conversations the app starts. Examples are its scheduler, its `summon` and delegation of work to
subagents, and anything that saves documents elsewhere. Where one cannot be taken away, it is
named as residue, the way three of Cursor's are. Goose's questions reach the person as a card
where Goose can ask over ACP. Otherwise the agent ends its turn with the question and shows
**Waiting on your answer**, as Grok does.

**Why this priority**: Without it Goose runs, but outside the app's rules: its turns end without
a report, it cannot lease or wait, and it can schedule or delegate work the app never sees. The
runtime policy table must cover every runtime in the catalog or a test fails, so this story has
to ship with the P1 stories before Goose is offered.

**Independent Test**: Start a Goose agent and ask it to list the tools it has. The app's tools
are listed and the removed ones are not. Ask it to end its turn with a report, to lease a
resource, to ask a question, and to schedule something. The first three arrive in the app as
they do for Claude. The fourth is refused, or is named residue.

**Acceptance Scenarios**:

1. **Given** a Goose agent, **When** it starts, **Then** it is given the app's tools and the same briefing as other runtimes.
2. **Given** a Goose agent, **When** it ends a turn, **Then** it reports the turn's outcome through the app's tool, as Claude does.
3. **Given** Goose's own tools that overlap with the app's (scheduling, starting or delegating to other agents, notifications, saving documents elsewhere), **When** the app starts a Goose agent, **Then** those are removed. Where they cannot be removed, they are named as residue in the policy and in the briefing.
4. **Given** Goose's scheduler, **When** the app starts Goose, **Then** it is never switched on for the app's agents.
5. **Given** a Goose agent that needs an answer mid-turn, **When** it asks, **Then** the person sees a question card if Goose can ask over ACP, and otherwise the agent shows **Waiting on your answer** with the question.
6. **Given** the app's tools reach Goose, **When** Goose's mode would ask before running one of them, **Then** the app's tools are not held behind Goose's approval where Goose allows exempting them. Where it does not, the briefing does not promise otherwise.
7. **Given** the person's own Goose extensions (MCP servers enabled in their Goose config), **When** the app starts a Goose agent, **Then** the app changes none of them. Whether they load in the app's agents is recorded in the plan's research, and one that duplicates the app's remit is named as residue *(default D6)*.
8. **Given** the same Goose started from Terminal, **When** the person uses it there, **Then** it has every tool, extension and setting it always had *(default D6)*.

---

### User Story 5 - Goose on servers (Priority: P3)

The person has a bare Linux server added as in 043. In Settings ▸ Runtime credentials, they add
a Goose server credential: they pick Anthropic, paste an Anthropic API key, and optionally pick a
model. When they start a Goose agent in a project on that server, the server installs Goose's
pinned release the first time, with its progress in the set-up checklist. The agent then runs on
Anthropic with the key lent from the Mac. The key is never written to the server's disk, and the
Mac's own Goose configuration stays on the Mac.

**Why this priority**: It extends 043 to Goose. That matters for the ephemeral servers 043 is
about, but the Mac comes first.

**Independent Test**: With a Goose server credential in Settings and a Linux server with nothing
on it, start a Goose agent in a server project and ask it to run `uname -a`. The reply comes
back from the chosen provider. Afterwards, a search of the server's disk finds the key nowhere,
and no `~/.config/goose` was copied from the Mac.

**Acceptance Scenarios**:

1. **Given** Settings' runtime credentials, **When** the person opens them, **Then** Goose is listed beside the others, with a provider picker (Anthropic, OpenAI, Google, OpenRouter), where to get that provider's key, an optional model, and a field to paste the key *(default D2, D2a)*.
2. **Given** a pasted key, **When** it is saved, **Then** the app checks it with that provider, says in words whether it works, keeps it only in the Mac's Keychain, and shows it masked afterwards.
3. **Given** a server without Goose, **When** Goose is first needed there, **Then** the server installs the pinned Linux release for its architecture, checks it against the app's checksums and FR-003, and shows its progress. A failed install names its cause and leaves nothing half-installed *(default D2, D7)*.
4. **Given** a Goose agent starting on a server, **When** it starts, **Then** the provider, model and key reach that run only, as Goose's environment. They are not written to the server's disk, any log or any transcript, and are not sent to a server for any other runtime.
5. **Given** a server marked "use this server's own sign-in only" (043), **When** a Goose agent starts there, **Then** nothing is lent, and the server's own Goose configuration is used.
6. **Given** no Goose server credential in Settings and no Goose configuration on the server, **When** the person starts a Goose agent there, **Then** the app asks for a provider and key in place before starting. It never copies the Mac's Goose configuration or Keychain keys.
7. **Given** a Goose agent on a server, **When** the person opens its model menu, **Then** it shows what Goose reports there. A switch to a provider with no key on the server says so, as on the Mac (Story 3, scenario 4).

---

### Everywhere a runtime is chosen

Goose is offered wherever another runtime is: a workflow's steps, the phone's and iPad's start
forms, the runtime menu above the prompt, and `start_agent` from another agent. On a server
project it is offered when it is installed there, or can be installed there (User Story 5).

### Edge Cases

- **Pressly/goose on the PATH.** The migration tool is never started, never counted as Goose, and never named as a Goose install anywhere in the app *(default D1, FR-003)*.
- **Goose not installed yet, installing, or failed to install.** Choosing Goose says which, and offers the set-up row's action. It never starts and then fails. An install that fails says why in 048's words (offline, a download that does not match its checksum, no room, an unsupported Mac), with **Retry** and **Open install page**. Nothing half-installed is ever used.
- **Goose Desktop installed, no CLI.** Goose reads as not on this Mac. The app does not start anything inside `Goose.app` and does not change it.
- **A Goose release changes `goose acp` or drops it.** The agent says Goose did not start in a mode the app can talk to, and names the version. It does not hang. A check script can measure it again.
- **Keychain access for the app's copy.** Goose keeps provider keys in the Mac's Keychain. A key saved by the person's own `goose` may make macOS ask whether the app's copy, a different program, may read it. If that prompt appears, the app says what it is in a sentence the first time. It never answers the prompt for the person and never copies a key.
- **A provider set only in the environment.** `GOOSE_PROVIDER`, `GOOSE_MODEL`, `GOOSE_MODE` or a provider's key in the environment the app was launched with are Goose's business. Goose lets them override its config file. The app neither adds nor strips them, so a Goose agent may use a different provider from Goose in a Terminal without them.
- **Another agent as Goose's provider.** Goose can use Claude Code, Codex, Cursor Agent or another ACP agent as its provider. A Goose agent on such a provider is still a Goose agent in the app. Its usage and cost are whatever Goose reports, the other agent's sign-in is that agent's, and the app does not also count it as that runtime.
- **A local provider that is not running.** Ollama or another local server that is down refuses the turn. The turn ends with Goose's reason in a sentence, not as a sign-in failure.
- **`chat` mode.** A Goose agent in `chat` mode calls no tools, including the app's, so its turns end without the app's report. The modes menu says so under `chat`, and the app shows the ending as an ending in `chat` mode, not as a failure.
- **Credits exhausted.** Goose reports this apart from other errors. The turn ends with a sentence saying the provider's credits ran out, distinct from a refused key.
- **A picture attached.** It goes as a picture, since Goose says it takes pictures, unless the chosen model cannot read pictures. In that case Goose's own refusal is shown in a sentence.
- **The person's Goose recipes, skills and sessions.** They are never written by the app. The app's Goose sessions are saved where Goose saves sessions, so they also appear in Goose's own session list and in Goose Desktop. The plan records whether that can be avoided, and the docs say it if not.
- **An unsupported Mac.** If the pinned release has no build for this Mac, Goose is shown as unavailable, with the reason, and it is not offered in the start form.
- **A server with its own `goose`.** A `goose` already on the server, whether Goose or the migration tool, is not used or changed. The server runs the app's pinned copy, as on the Mac *(default D1, D2)*.
- **A key the provider refuses on a server.** The agent stops with a sentence saying the provider refused the Goose server key, with a way to replace it, and this reads differently from any other failure (043 FR-016).
- **A server credential for a provider the server cannot reach.** A firewall or a region block is Goose's error. The turn ends with it in a sentence, not as a refused key.

## Requirements *(mandatory)*

### Functional Requirements

**Starting Goose on the Mac**

- **FR-001**: The app MUST list Goose among the runtimes it can start, everywhere a runtime is chosen: the Mac's start form and runtime menu, the phone and iPad start forms, workflow steps, and `start_agent`.
- **FR-002**: Goose MUST have a row on the set-up page (start-up sheet, Settings ▸ Agents, empty project list). Its **Install** puts the pinned Goose release for this Mac's architecture in the app's own folder, checked against a checksum the app carries. Goose MUST need nothing installed beforehand *(default D1, D7)*.
- **FR-002a**: Agents MUST run only the app's copy of Goose. A `goose` the person installed, whether Goose or not, MUST NOT be used, changed or removed, and MUST NOT make Goose's row read as installed *(default D1)*.
- **FR-003**: Any `goose` the app considers, whether its own copy after an install or one found on a server, MUST identify itself as Goose (by its version output or its ACP `initialize` answer naming the agent `goose`) before the app counts it as installed. A program that fails this check MUST be reported as "not Goose", never started for an agent.
- **FR-003a**: If Goose's own install script is ever run by the app, it MUST be run with `CONFIGURE=false`, MUST NOT edit the person's shell start-up files, and MUST NOT wait on a terminal *(default D1a)*.
- **FR-004**: Starting a Goose agent when Goose is not installed, still installing, or failed to install MUST say which and offer the row's action, and MUST never start and then fail.
- **FR-004a**: A running Goose agent MUST keep the build it started on when a newer one is installed *(default D7)*.
- **FR-005**: A Goose agent MUST show replies, tool calls, permission asks, file changes, stop and resume the way the app shows them for other runtimes, limited only by what Goose reports over ACP.
- **FR-006**: Usage and cost MUST be shown where Goose reports them, and left out (never shown as zero) where it does not.
- **FR-007**: What Goose can do in the app (pictures, sign-in, resume, modes, providers, models, thinking effort) MUST follow what it says about itself when it starts and in each session, not a list kept by the app.

**Providers and signing in**

- **FR-008**: A Goose agent that cannot start, or a turn that is refused, because Goose has no usable provider MUST say so and offer the runtime sign-in sheet. It MUST NOT fail silently or wait forever.
- **FR-009**: The sheet MUST say that Goose uses a provider of the person's choosing and MUST hand over Goose's own set-up command, naming the app's copy by full path, with **Open Terminal** and **Copy**. It MUST show no sign-out button *(default D3)*.
- **FR-010**: The app MUST NOT ask for, keep or pass a provider key for Goose on the Mac. A Goose agent MUST use the provider the person's Goose is configured with, or the one its environment names *(default D3)*.
- **FR-011**: Goose's provider, model and thinking-effort choices MUST show in the model menu as Goose reports them. A change MUST apply to that agent only and MUST NOT change the person's saved Goose defaults. A choice that cannot be made without changing them MUST NOT be offered *(default D4)*.
- **FR-012**: A turn refused for a rejected provider key, exhausted credits, a rate limit or an unreachable local provider MUST end with a sentence naming which, never an endless wait or "stopped answering".

**Modes**

- **FR-013**: Goose's modes MUST show as the agent's modes, with Goose's descriptions. A Goose agent MUST start in the person's own Goose mode until one is picked in the app. After that, the last mode picked MUST be remembered for Goose, and helpers MUST inherit it as they do for other runtimes *(default D5)*.
- **FR-014**: The current mode of a Goose agent MUST be visible wherever the app shows an agent's mode, including when it is `auto` *(default D5)*.

**The app's tools and scoping**

- **FR-015**: A Goose agent MUST be given the app's tools and the same briefing as other runtimes.
- **FR-016**: The runtime tool policy MUST have an entry for Goose. It removes Goose's tools that duplicate the app's (standing arrangements, starting or delegating to agents, notifications, artefact stores) and names as residue any it cannot remove. The policy MUST cover every runtime in the catalog, and a test MUST say so.
- **FR-017**: The app MUST NOT switch on Goose's scheduler for its agents.
- **FR-018**: A Goose agent's mid-turn question MUST reach the person as a card if Goose can ask over ACP, and otherwise as **Waiting on your answer** with the question.
- **FR-019**: The app's own tools MUST NOT be held behind Goose's approval prompts where Goose allows exempting them. Where it does not, the briefing MUST NOT claim they run without asking.
- **FR-020**: The app MUST NOT write to `~/.config/goose` or Goose's Keychain items, and MUST NOT point Goose at another config folder. Everything it sets for its own agents MUST be passed when it starts that agent *(default D6)*.

**Goose on servers**

- **FR-021**: Settings' runtime credentials MUST list Goose. It takes one provider (Anthropic, OpenAI, Google or OpenRouter), that provider's API key, and an optional model. The app MUST check the key with that provider on save, say in words whether it works, keep it only in the Mac's Keychain, and show it masked afterwards *(default D2, D2a)*.
- **FR-022**: A server MUST install Goose's pinned Linux release on demand, from official sources, checked against checksums the app carries and FR-003, with progress in the set-up checklist. An incomplete install MUST never be used, and a `goose` already on the server MUST NOT be used or changed *(default D2, D7)*.
- **FR-023**: The Goose server credential MUST reach a server only as Goose's environment when starting Goose there, for that run. It MUST NOT be written to the server's disk, any log, transcript or crash report, or sent for any other runtime.
- **FR-024**: The Mac's Goose configuration and its Keychain keys MUST NOT be copied, lent or sent to any server.
- **FR-025**: 043's rules for servers MUST hold for Goose as they do for Claude: a server's "own sign-in only" mark, asking for the credential in place when none is usable, a refused key shown as its own failure, and a rebuilt server set up again on confirmation.

### Key Entities

- **Goose runtime**: an entry in the app's runtime list. It holds its name, how it is started (the app's copy of `goose`, with the `acp` subcommand), how it is installed (a pinned release from the set-up page), how it is recognised (FR-003), and what it says about itself when it starts.
- **Goose release**: the pinned Goose version, with a download and a checksum for each platform (macOS and Linux, ARM64 and x86-64). On the Mac it is installed in the app's own folder from the set-up page. On a server it is one of 043's installed tools. Either way it is replaced as a whole.
- **Goose session options**: what Goose reports for each agent (provider, model, thinking effort, mode), shown in the app's menus, changed for that agent only.
- **Goose server credential**: one provider, that provider's API key and an optional model, for servers only. It is kept in the Mac's Keychain and masked when shown, with when it was added and when it last worked. This is 043's runtime credential, gaining a kind that names its provider.
- **Goose tool policy**: which of Goose's tools are removed for the app's agents, which remain as residue and why, how its questions reach the person, and whether the app's tools are exempt from its approval prompts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Mac with nothing installed, a person who already has a provider key goes from pressing **Install** on the set-up page to a Goose agent's first reply within 3 minutes, counting the provider set-up.
- **SC-002**: A later Goose start takes no more than 5 seconds longer to reach its first reply than a Claude start on the same Mac, with the same provider's model.
- **SC-003**: On a Mac with pressly/goose on the PATH, in 10 of 10 tries the app never starts it and never shows Goose as installed because of it.
- **SC-004**: Every failure in the edge cases above shows as a sentence naming its cause. None shows as an endless wait or as "stopped answering".
- **SC-005**: After a day of Goose agents in the app, including switching provider, model and mode in the menus, the person's `~/.config/goose` is byte for byte what it was before.
- **SC-006**: A Goose agent's turns end with the app's outcome report in at least 9 of 10 turns in modes that allow tools, as measured for the other runtimes that have the app's tools.
- **SC-007**: From a bare Linux server, a person with a Goose server credential in Settings gets a Goose agent's first reply within 5 minutes, having run no command on the server. Afterwards, a search of the server's disk and the Mac's logs finds the key in neither, and finds no copy of the Mac's Goose configuration on the server.

## Docs *(mandatory)*

- `docs/reference/runtimes.md` — change: the runtime count, plus a Goose row: command `goose acp` (the app's copy), pictures, sign-in (hands over `goose configure`), app tools, notes on modes (`auto` approves on its own), providers, and residue. Name the pressly/goose trap in the notes, as Cursor's row names `agent`.
- `docs/how-to/sign-a-runtime-in.md` — change: name Goose among the runtimes, and explain that signing Goose in means choosing a provider with `goose configure`.
- `docs/explanation/scoped-tools.md` — change: add Goose's removed tools and its residue.
- `docs/how-to/add-a-linux-server.md` — change: Goose installs on a server as Claude does, it takes a provider and that provider's key from Settings, and why the Mac's own Goose set-up stays on the Mac.
- `docs/reference/settings.md` — change: the runtime credentials entry lists Goose's server credential (provider, key, optional model).

## Assumptions

- **Measured from Goose's source and docs, not from a running Goose.** No `goose` is installed on this Mac. This spec did not run Goose's installer, did not install it into the real home, and did not start it. What it states about Goose's ACP comes from reading `aaif-goose/goose` at `04ed836` (2026-09-25), release 1.52.0:
  - `goose acp` is a real subcommand ("Run goose as an ACP agent server on stdio"), with optional `--with-builtin` and `--enable-scheduler`. `goose serve` is the HTTP/WebSocket form, which the app does not use.
  - `initialize` answers with agent `goose`, loading sessions, listing/deleting/closing sessions, images, embedded context and HTTP MCP servers. It advertises one auth method, `goose-provider` "Configure Provider", of the *agent* kind, described as "Run `goose configure` to set up your AI provider and API key". Its `authenticate` does nothing.
  - A session that cannot create its provider, and a turn whose provider refuses authentication, both fail with ACP's `auth_required` error. Exhausted credits fail with their own error.
  - Each session reports config options `provider` (with "Goose (Default)" meaning the configured default), `mode`, `model` and `thinking_effort`. Modes are `auto` (default), `approve`, `smart_approve` and `chat`.
  - Permission asks use ACP's `session/request_permission` with allow once / allow always / reject once / reject always. A form elicitation from an MCP server is forwarded as an ACP elicitation when the client says it supports one.
  - Goose's own overlapping tools include `scheduler__manage_schedule` (only with `--enable-scheduler`), `summon` and delegation to subagents, `extensionmanager__manage_extensions` (which can switch on more extensions mid-session), and `chatrecall`.
- **The plan's research must measure, against a real Goose in a scratch home:** the checksum and download for each architecture; whether the macOS build runs without a Gatekeeper prompt when fetched by the app; that `goose --version` and `initialize` identify it (FR-003); whether an unconfigured Goose fails at `session/new` or at the first prompt; whether switching `provider` or `model` over ACP writes `config.yaml` (D4 turns on this); how to remove or disable `summon`, the extension manager and the person's own extensions for one session without writing their config; whether the app's MCP tools can be exempt from Goose's approval; whether Goose raises a question of its own over ACP; the Keychain prompt for the app's copy; where the app's Goose sessions are saved; and whether the Linux build (glibc or musl) runs on 043's supported servers. Alex's provider key is needed for the live proof.
- **Builds on 048** (the set-up page and Mac installs, merged `ee64697`) and on 047's groundwork for "only the app's copy" runtimes and pinned updates. Goose is the first app-copy runtime that is a single native program with no Node beside it.
- `LoginShellPath.fallbacks` searches `~/.local/bin`, where Goose's own installer puts `goose` by default (`GOOSE_BIN_DIR`). With D1 that only matters for recognising (and ignoring) the person's own copy. Installing there, as Grok, Copilot and Cursor do, was turned down because `/opt/homebrew/bin` comes first, which is exactly the trap.
- 046, 047 and this spec each add a runtime, a policy entry and a set-up row. Whichever merges later takes the others' rows.
- The phone and iPad start Goose agents through the Mac. Nothing Goose-specific runs on them.
- Goose reads its provider, model and the provider's key from its environment, which overrides its config file (per Goose's provider docs). So a server can be signed in by lending them per run, as 043 does for Claude. The plan measures this against the pinned release, including that Goose does not try to save a key it was given only in its environment.
- Browser-sign-in, cloud-account and local providers on servers, and more than one Goose server credential, are out of scope *(default D2a)*.

## Sources

- Goose installation: <https://goose-docs.ai/docs/getting-started/installation> — the one-liner `curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | bash`, `CONFIGURE=false`, Homebrew `block-goose-cli` and cask `block-goose`.
- Goose's install script (read, not run): <https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh> — `GOOSE_BIN_DIR` defaults to `$HOME/.local/bin`; `goose-<arch>-apple-darwin.tar.bz2`; no checksum check; `goose configure` and the rc-file prompt read `/dev/tty` unless `CONFIGURE=false`.
- Goose as an ACP agent: <https://goose-docs.ai/docs/gdk/acp/> — `goose acp` over stdio, `goose serve` over HTTP/WebSocket.
- Providers and config: <https://goose-docs.ai/docs/getting-started/providers> — `~/.config/goose/config.yaml`, keys in the Keychain with `secrets.yaml` as fallback, `GOOSE_PROVIDER` and `GOOSE_MODEL` override the file, and CLI pass-through and ACP providers.
- Goose source: <https://github.com/aaif-goose/goose> at `04ed836`: `crates/goose-cli/src/cli.rs` (the `Acp` command), `crates/goose/src/acp/server.rs` (`initialize`, auth mapping, `DEFAULT_PROVIDER_ID`), `crates/goose/src/acp/response_builder.rs` (modes, models, config options), `crates/goose/src/acp/server/dispatch.rs` (config option switches), `crates/goose-provider-types/src/goose_mode.rs` (the four modes).
- Homebrew: <https://formulae.brew.sh/formula/goose> (pressly/goose, the migration tool) and <https://formulae.brew.sh/formula/block-goose-cli> (`conflicts_with "goose"`, "both install `goose` binaries").
- ACP agents list: <https://agentclientprotocol.com/overview/agents>.
