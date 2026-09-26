# Feature Specification: OpenCode as a Runtime

**Feature Branch**: `agents/write-spec-adding-opencode`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Add OpenCode (sst/opencode) as a built-in runtime."

## Why this feature exists

The app starts four runtimes: Claude, Grok, Copilot and Cursor. 046 adds Gemini and 047 adds
Codex. OpenCode is the open-source coding agent from the SST team (its repository has since
moved to `anomalyco/opencode`). Its draw is that it is not tied to one model vendor. One
program signs in to Anthropic, OpenAI, GitHub Copilot, OpenRouter, a local model or any of 75
others, and switches between them per conversation. People who use it today keep a terminal
open beside the app, and none of that work shows up in the app's lists, on the phone, in
workflows or in leases.

OpenCode speaks the agent protocol (ACP) itself, with its own subcommand. It is one
self-contained program with no Node to carry, installed by a one-line script. So it fits the
recipe Grok, Copilot and Cursor already follow: an executable, its ACP arguments, an install
script and an install page. The work is in the parts where OpenCode differs:

- **Its name is not unique.** A different, archived program also installed itself as
  `opencode` (see *The name trap* below).
- **Its installer puts it where the app does not look.**
- **Its sign-in is a terminal step, not an ACP step.**
- **It updates itself by default, and can share conversations to the web.**
- **Its question tool is switched off over ACP.**

**This feature makes OpenCode a runtime like the others on the Mac**, installed from 048's
set-up page, and makes sure that the `opencode` the app starts is always the right one.

## The name trap *(the reason this spec exists as more than one catalog line)*

`RuntimeCatalog.swift`'s header records the Cursor trap: Cursor's docs call its program
`agent`, and `agent` on this Mac is Grok. OpenCode's trap is the same kind, and it has three
parts.

1. **Two programs are called `opencode`.** Until mid-2025, `opencode-ai/opencode` was a Go
   terminal agent whose binary was also `opencode`. It was archived at v0.0.55 (2025-06-27) and
   continues as Charm's **Crush**. That old binary is still on Macs that installed it through
   its Homebrew tap. It has no `acp` subcommand. The SST program (now `anomalyco/opencode`,
   1.18.32 on 2026-09-21) kept the name. **What the app starts is `opencode acp` from the
   SST/anomalyco program.** A PATH lookup for `opencode` does not tell the two apart.
2. **Two npm packages look right.** The real package is `opencode-ai`. A bare `opencode` on npm
   is not it. The app never installs either with npm (D1).
3. **The installer lands outside the app's search path.** `curl -fsSL https://opencode.ai/install | bash`
   always installs to `~/.opencode/bin/opencode`. The folder is hard-coded (`INSTALL_DIR=$HOME/.opencode/bin`
   in the script, with no variable to move it). `LoginShellPath.fallbacks` searches
   `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.grok/bin` and `~/.bun/bin`, but **not
   `~/.opencode/bin`**. The script does add that folder to the PATH, but zsh users get it in
   `~/.zshrc`, the first of its candidate files that exists. The app reads the PATH with a
   login, non-interactive `zsh -lc`, which never reads `~/.zshrc`. So on a typical Mac, a
   successful install would be followed by 048's "installed, but not where the app looks"
   failure, unless the fallbacks gain `~/.opencode/bin`.

So the spec requires three things (FR-002 to FR-004). The app finds OpenCode in `~/.opencode/bin` whatever the
shell's configuration. It treats an `opencode` as OpenCode only when that program speaks ACP.
And it says so plainly when the `opencode` it found is the other one.

## Defaults taken *(Alex to confirm or overturn)*

These are defaults so that the spec is complete. Each is marked *(default Dn)* where it is
used.

- **D1. Installed with OpenCode's own script, like Grok, Copilot and Cursor.** OpenCode's row on
  048's set-up page runs `curl -fsSL https://opencode.ai/install | bash`. It lands in
  `~/.opencode/bin`, which the app starts searching. It is a single self-contained program, so
  unlike Claude, Gemini and Codex there is no Node for the app to carry. An `opencode` the person
  already installed (the same script, Homebrew `anomalyco/tap/opencode`, or npm `opencode-ai`)
  counts as installed, if it speaks ACP. *Alternative: the app's own pinned copy of the release
  program, in the app's folder, checked against the SHA-256 digests GitHub publishes for each
  release, as 046 and 047 settled for Gemini and Codex.*
- **D2. On the Mac only, in this version.** OpenCode is not offered for server projects yet.
  043's servers lend one credential per runtime, and OpenCode's sign-in is not one credential:
  it is a list of providers, each with its own key or account. What to lend a server needs its
  own decision. *Alternative: servers too, lending one provider's key (for example the Anthropic
  key 043 already keeps).*
- **D3. OpenCode's own sign-in, left where it is.** An agent on the Mac uses whatever providers
  OpenCode is already signed in to (`~/.local/share/opencode/auth.json`) and any provider key
  already in the environment it inherits (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and so on,
  which OpenCode reads itself). The app keeps no copy and adds no key. Signing in is OpenCode's
  own `opencode auth login`, handed over as a terminal step, as Copilot's is.
- **D4. The person's own OpenCode settings are left alone, and the app's agents run as the
  app needs.** The app writes nothing to `~/.config/opencode`, `~/.local/share/opencode` or a
  project's `opencode.json`. What it needs for its own agents is passed when it starts that
  agent, through OpenCode's inline configuration (`OPENCODE_CONFIG_CONTENT`), which OpenCode
  merges over the person's own. That covers turning off self-update, turning off sharing, and
  removing the tools that duplicate the app's. It holds for that agent only.
- **D5. No self-update under the app's agents.** OpenCode updates itself by default. An agent the
  app starts has self-update turned off (D4), so that a running agent keeps the program it
  started with. The set-up page, and OpenCode in Terminal, are how it moves on.
- **D6. OpenCode's agents are the agent's modes; its providers' models are the model menu.**
  OpenCode reports its primary agents (normally `build` and `plan`) as ACP modes, and its models
  (every model of every signed-in provider) with their reasoning levels. The app shows them as
  it shows another runtime's modes and models, and remembers the last mode picked for OpenCode.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start an OpenCode agent on the Mac (Priority: P1)

The person has OpenCode signed in to at least one provider, or has never installed it. The set-up
page lists OpenCode (offered once, even to someone who dismissed the page before), as **Not on
this Mac** with **Install**, or ticked if their own copy speaks ACP. In the start form,
**OpenCode** is in the runtime list beside the others. They choose it and type a prompt. Then
OpenCode works like any other runtime: it replies as it thinks, calls tools, asks permission
where its settings say to, shows the diffs of the files it changes, reports usage and cost, can
be stopped mid-turn, and can be resumed later with its history.

**Why this priority**: It is the request. Without it the other stories have nothing to act on.

**Independent Test**: On a Mac with OpenCode signed in to one provider, start an OpenCode agent
in a project and ask it to create a file and run `ls`. The reply streams in, the tool calls
show, the file appears in the changes, and a later resume continues the conversation.

**Acceptance Scenarios**:

1. **Given** the start form, **When** the person opens the runtime list, **Then** OpenCode is listed with the other runtimes, and a new conversation can be started with it.
2. **Given** a Mac without OpenCode, **When** the app starts, **Then** the set-up page lists OpenCode as not on this Mac with **Install**, once, even if the person dismissed the page before for other agents. The same row is in Settings ▸ Agents from then on.
3. **Given** OpenCode's row, **When** the person presses **Install**, **Then** OpenCode's script runs, the row shows its progress, and the row ticks with `~/.opencode/bin/opencode` as where it is. This holds on a Mac whose shell configuration never puts `~/.opencode/bin` on a login PATH *(default D1)*.
4. **Given** a running OpenCode agent, **When** it edits files, runs commands or asks permission, **Then** each shows in the conversation the way the same act from another runtime does. A permission ask offers OpenCode's three answers (allow once, always allow, reject) and can be answered on the Mac or the phone.
5. **Given** an OpenCode agent mid-turn, **When** the person stops it, **Then** the turn ends and the agent can be given a new prompt.
6. **Given** a stopped or parked OpenCode agent, **When** the person resumes it, **Then** it continues the same conversation with its history.
7. **Given** the modes menu for an OpenCode agent, **When** the person opens it, **Then** it lists OpenCode's own primary agents (normally **build** and **plan**). The one picked applies from the next turn, and is remembered for the next OpenCode agent *(default D6)*.
8. **Given** the model menu for an OpenCode agent, **When** the person opens it, **Then** it lists the models of every provider OpenCode is signed in to, with the provider named, and the reasoning levels where a model has them *(default D6)*.
9. **Given** a finished OpenCode turn, **When** it ends, **Then** its token use and its cost in dollars show as for other runtimes. Where OpenCode reports a cost of zero for a model with no per-token price (a subscription or a local model), no cost is shown rather than "$0.00".

---

### User Story 2 - The right `opencode`, or a plain sentence (Priority: P1)

The person has an `opencode` on the PATH that is not the one the app can talk to. It might be the
archived Go program of the same name, or a copy too old to have `acp`. They do not get an agent
that hangs, or one that prints a terminal interface into the conversation. OpenCode's row says
what was found and why it cannot be used, and offers **Install**, which puts the right one in
`~/.opencode/bin`.

**Why this priority**: This is the trap the spec exists to rule out. It ships with Story 1.

**Independent Test**: On a scratch root, put a fake `opencode` earlier on the search path that
has no `acp` subcommand (it prints its usage and exits, or starts a terminal interface). OpenCode's
row reads as not usable, with the reason. Starting an OpenCode agent says the same, within
seconds. After **Install** (pointed at a test script), the row ticks and an agent starts.

**Acceptance Scenarios**:

1. **Given** an `opencode` that does not answer ACP's opening handshake as OpenCode, **When** the app checks it, **Then** the row says "The `opencode` in <folder> isn't OpenCode's current program" (or words to that effect) and offers **Install**. It never shows a tick.
2. **Given** both a wrong `opencode` earlier on the PATH and the right one in `~/.opencode/bin`, **When** an OpenCode agent starts, **Then** the app starts the right one.
3. **Given** a wrong `opencode`, **When** the person installs OpenCode from the row, **Then** the wrong one is not changed, moved or removed. Their terminal keeps resolving whatever it resolved before.
4. **Given** a program that starts but never answers, **When** the app starts it as OpenCode, **Then** within the app's usual start-up limit the agent ends with a sentence naming the program's path. It never waits forever.

---

### User Story 3 - Sign OpenCode in (Priority: P2)

The person starts an OpenCode agent with no provider signed in, or picks a model whose provider
is not signed in. They do not get a silent failure or an empty reply. The agent says OpenCode
needs a provider signed in, and names that provider when OpenCode names it. The runtime menu shows
**Needs signing in** beside OpenCode, and **Sign in, sign out, providers…** opens the same sheet the
other runtimes use. There, OpenCode's only sign-in choice is its own
`opencode auth login`, handed over with **Open Terminal** and **Copy**, as for Copilot. That
command lists OpenCode's providers and runs each one's own browser, device-code or key step.

**Why this priority**: Many people trying OpenCode here will have installed it from the set-up
page a moment ago, with nothing signed in.

**Independent Test**: With OpenCode's sign-in file moved aside on a scratch home, start an OpenCode
agent and prompt it. The turn ends saying a provider needs signing in, and the sheet offers the
command. Run it in Terminal, sign in to one provider, and the next turn works.

**Acceptance Scenarios**:

1. **Given** OpenCode with no usable provider, **When** a turn is refused for it, **Then** the agent says OpenCode needs signing in, naming the provider if OpenCode named it. It never waits forever or shows only "stopped answering".
2. **Given** the sign-in sheet for OpenCode, **When** it opens, **Then** it shows `opencode auth login` with **Open Terminal** and **Copy**, and a line saying which providers OpenCode is signed in to, if the app can tell *(default D3)*.
3. **Given** OpenCode's ACP sign-in step, **When** the app would call it, **Then** the app does not treat it as signing anyone in. OpenCode's `authenticate` accepts the call and does nothing, so a "signed in" state never comes from it.
4. **Given** the sheet, **When** the person looks for **Sign out**, **Then** there is none, as for Cursor. Signing a provider out is `opencode auth logout` in Terminal, which the sheet names.
5. **Given** a provider key already in the environment the app started with, **When** an OpenCode agent starts, **Then** OpenCode can use it, and the app neither adds nor removes such a key *(default D3)*.

---

### User Story 4 - The app's own tools and scoping (Priority: P2)

An OpenCode agent works inside the app the way a Claude agent does. It has the app's tools: it
ends its turn with a report, asks questions, leases resources, waits for events, starts helpers,
and starts and runs workflows. OpenCode's own tools that duplicate the app's are taken away for
the conversations the app starts. Where one cannot be taken away, it is named as residue. OpenCode's
question tool is off over ACP, so when an OpenCode agent needs an answer it uses the app's
question tool. If it ends its turn with a question in plain words instead, the agent shows
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
6. **Given** the same OpenCode started from Terminal, **When** the person uses it there, **Then** it has every tool and setting it always had, and the app has changed none of them *(default D4)*.
7. **Given** the person's own OpenCode setup (their MCP servers, custom agents, commands and `AGENTS.md` rules), **When** an OpenCode agent starts in the app, **Then** OpenCode loads them as it would in Terminal, except for the tools the app removed.

---

### Everywhere a runtime is chosen

OpenCode is offered wherever another runtime is on the Mac: a workflow's steps, the phone's and
iPad's start forms (which start agents through the Mac), the runtime menu above the prompt, and
`start_agent` from another agent. It is not offered on server projects in this version
*(default D2)*.

### Edge Cases

- **The archived Go `opencode`, or an old SST one.** Found first on the PATH, it is not used, and the row says why (Story 2). The right one in `~/.opencode/bin` wins over it when both are there.
- **`~/.opencode/bin` only in `~/.zshrc`.** The app still finds it, because it searches that folder itself (FR-002).
- **Install fails.** Offline, GitHub's release lookup refused (the script asks GitHub's API for the latest version, which can be rate-limited), `unzip` missing, or no room. The row says which, in 048's wording, with **Retry** and **Open install page**. The script checks no checksum. That is recorded, not hidden (see Assumptions).
- **The script edits the person's shell file.** OpenCode's script adds `~/.opencode/bin` to the first of `~/.zshrc`, `~/.zshenv` and so on that exists. That is the vendor's behaviour, as Grok's and Cursor's is. Whether the app passes `--no-modify-path`, so it edits nothing, is decided in planning together with D1. Either way the app finds the program without the edit.
- **Self-update.** OpenCode replaces its own program while running if it is allowed to. The app's agents run with it off (D5). A Terminal session of the person's may still update the shared program, and a running app agent keeps the process it started.
- **A model the provider no longer serves, or a provider signed out mid-session.** The turn ends with OpenCode's reason in a sentence, as for a refused sign-in, and the model menu is refreshed at the next start.
- **Rate limits and quota.** A provider's rate limit or exhausted quota ends the turn with the reason in a sentence, not as a crash.
- **No provider at all, but a free model.** If OpenCode offers a model that needs no sign-in, a turn with it works and the agent does not claim to need signing in. Whether any such model exists is measured in planning.
- **`/undo` and `/redo`.** OpenCode's docs say these slash commands do not work over ACP. The app does not offer them for OpenCode.
- **Pictures.** OpenCode says it takes pictures over ACP, so a picture attached for an OpenCode agent goes as a picture. The model chosen may still refuse it, and that refusal shows as OpenCode words it.
- **A project's own `opencode.json`.** It loads in the app's agents as in Terminal. The app's inline settings are merged over it and win only for the keys the app sets (D4).

## Requirements *(mandatory)*

### Functional Requirements

**Starting OpenCode on the Mac**

- **FR-001**: The app MUST list OpenCode among the runtimes it can start on the Mac: the Mac's start form and runtime menu, the phone and iPad start forms, workflow steps, and `start_agent`. It MUST start it as `opencode acp`.
- **FR-002**: The app MUST look for OpenCode in `~/.opencode/bin` whatever the login shell's PATH says, as it already does for `~/.grok/bin` and `~/.local/bin`.
- **FR-003**: The app MUST treat an `opencode` as OpenCode only if that program, started with `acp`, answers ACP's opening handshake as OpenCode. A program that does not, whether the archived Go `opencode`, an SST release too old to have `acp`, or anything else of that name, MUST NOT be shown as installed or started for an agent.
- **FR-004**: Where more than one `opencode` is found, the app MUST use the first that passes FR-003. Where none passes, it MUST name the one it found and why it cannot be used, and offer **Install**.
- **FR-005**: OpenCode MUST have a row on 048's set-up page, offered once to people who already dismissed the page. Its **Install** runs OpenCode's own install script, and the install counts as done only when FR-003 then finds a usable OpenCode *(default D1)*.
- **FR-006**: The app MUST NOT use npm to install OpenCode, and MUST NOT change, move or remove an `opencode` it did not install.
- **FR-007**: An OpenCode agent MUST show replies, tool calls, permission asks, file changes, stop and resume the way the app shows them for other runtimes, limited only by what OpenCode reports over ACP.
- **FR-008**: Token use MUST be shown where OpenCode reports it. Cost MUST be shown where OpenCode reports a non-zero cost, and left out rather than shown as zero where it does not.
- **FR-009**: OpenCode's primary agents MUST show as the agent's modes, and its models (grouped or labelled by provider), with reasoning levels, as the model menu, both as OpenCode reports them. The last mode picked MUST be remembered for OpenCode, and helpers MUST inherit it as they do for other runtimes *(default D6)*.
- **FR-010**: What OpenCode can do in the app (pictures, resume, modes, models, sign-in) MUST follow what it says about itself when it starts, not a list kept by the app.
- **FR-011**: An OpenCode agent MUST run with self-update off, and MUST keep the program it started with until it ends *(default D5)*.

**Signing in**

- **FR-012**: A turn refused because a provider is not signed in (ACP's "authentication required") MUST end with a sentence saying OpenCode needs signing in, naming the provider when OpenCode names it, with a way to open the sign-in sheet. It MUST NOT fail silently or wait forever.
- **FR-013**: The sign-in sheet MUST offer `opencode auth login` as a terminal step, with **Open Terminal** and **Copy**, and MUST NOT offer an in-app sign-in or sign-out that OpenCode cannot carry out over ACP.
- **FR-014**: The app MUST NOT report OpenCode as signed in on the strength of OpenCode's ACP `authenticate` answer alone.
- **FR-015**: The app MUST NOT keep a copy of OpenCode's sign-in, and MUST NOT add or remove provider keys in an OpenCode agent's environment *(default D3)*.

**The app's tools and scoping**

- **FR-016**: An OpenCode agent MUST be given the app's tools and the same briefing as other runtimes.
- **FR-017**: The runtime tool policy MUST have an entry for OpenCode. It removes OpenCode's tools that duplicate the app's (at least `task`, which starts sub-agents, and its to-do list) and names as residue any it cannot remove. The policy MUST cover every runtime in the catalog, and a test MUST say so.
- **FR-018**: Sharing MUST be off for every OpenCode agent the app starts.
- **FR-019**: An OpenCode agent's mid-turn question MUST reach the person through the app's question tool, or otherwise as **Waiting on your answer** with the question.
- **FR-020**: The app MUST NOT write to `~/.config/opencode`, `~/.local/share/opencode`, `~/.opencode` (beyond the install itself) or a project's OpenCode files. Everything it sets for its own agents MUST be passed when it starts that agent *(default D4)*.

**Failures**

- **FR-021**: A wrong `opencode`, OpenCode not installed or failed to install, an unanswered start, a provider not signed in, a model no longer served, and a rate limit or quota MUST each end with a sentence naming the cause, never an endless wait or "stopped answering".

### Key Entities

- **OpenCode runtime**: an entry in the app's runtime list: its name, its executable (`opencode`, recognised only when it speaks ACP), its ACP arguments (`acp`), its install script and page, and what it says about itself when it starts.
- **OpenCode tool policy**: which of OpenCode's tools are removed for the app's agents, which remain as residue and why, the per-agent settings the app passes (self-update off, sharing off), and how its questions reach the person.
- **OpenCode sign-in**: OpenCode's own list of signed-in providers in the person's home, read by OpenCode and never copied by the app.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Mac with nothing of OpenCode's, a person goes from pressing **Install** on the set-up page to an OpenCode agent's first reply within 3 minutes, counting one provider's sign-in, having typed no command except the one the sheet hands them.
- **SC-002**: With OpenCode installed and signed in, an OpenCode start reaches its first reply no more than 5 seconds later than a Claude start on the same Mac, using the same underlying model where possible.
- **SC-003**: With the archived Go `opencode` (or any program of that name without `acp`) first on the PATH, 10 of 10 OpenCode starts either use the right OpenCode or end within 10 seconds with a sentence naming the wrong program. None hangs.
- **SC-004**: Every failure in the edge cases above shows as a sentence naming its cause. None shows as an endless wait or as "stopped answering".
- **SC-005**: After a day of OpenCode agents in the app, the person's `~/.config/opencode` and `~/.local/share/opencode/auth.json` are byte for byte what they were before, and no conversation has been shared.
- **SC-006**: An OpenCode agent's turns end with the app's outcome report in at least 9 of 10 turns, as measured for the other runtimes that have the app's tools.

## Docs *(mandatory)*

- `docs/reference/runtimes.md` — change: the runtime count, plus an OpenCode row (command `opencode acp`, installed to `~/.opencode/bin`, pictures, sign-in through `opencode auth login`, modes are OpenCode's agents, models from every signed-in provider, app tools, residue, not on servers yet).
- `docs/how-to/sign-a-runtime-in.md` — change: name OpenCode, and describe `opencode auth login` and its providers.
- `docs/explanation/scoped-tools.md` — change: add OpenCode's removed tools, its residue, and why sharing is off.
- `docs/reference/runtimes.md` — also add, under OpenCode: "the `opencode` found isn't OpenCode" (the archived Go program of the same name) and what to do.

## Assumptions

- **Sources.** The facts in this spec come from the vendor's own docs and source, read on 2026-09-25. Nothing was installed or run:
  - ACP: <https://opencode.ai/docs/acp/> (the command is `opencode acp`, and `/undo` and `/redo` are unsupported).
  - Install: <https://opencode.ai/docs/> and the install script itself, <https://opencode.ai/install>, which redirects to <https://raw.githubusercontent.com/anomalyco/opencode/refs/heads/dev/install> (`INSTALL_DIR=$HOME/.opencode/bin`, `--no-modify-path`, `--version`, no checksum check, and the shell files it edits).
  - Config and precedence, including `OPENCODE_CONFIG_CONTENT`, `autoupdate`, `share`, `tools` and `permission`: <https://opencode.ai/docs/config/>.
  - Providers, `/connect`, `~/.local/share/opencode/auth.json` and environment keys: <https://opencode.ai/docs/providers/>.
  - ACP implementation, from `anomalyco/opencode` `dev`:
    - `packages/opencode/src/acp/service.ts`: `initialize` advertises `loadSession`, image and embedded-context prompts, HTTP and SSE MCP, and session close, fork, list and resume. It offers one auth method, "Login with opencode" ("Run `opencode auth login` in the terminal"), carrying a `terminal-auth` command only when the client says it supports that. `authenticate` is a no-op. Primary agents become modes, with default `build`.
    - `packages/opencode/src/acp/error.ts`: a missing provider is ACP's `-32000` "provider authentication required", with `providerId`.
    - `packages/opencode/src/acp/permission.ts`: permission options are allow once, always allow and reject.
    - `packages/opencode/src/acp/usage.ts`: `usage_update` carries context used and size, and the session's cost in USD.
    - `packages/opencode/src/acp/config-option.ts`: config options for model, effort and mode.
    - `packages/opencode/src/tool/registry.ts`: the `question` tool is enabled only for the `app`, `cli` and `desktop` clients, so it is off over ACP.
  - Latest release: <https://github.com/anomalyco/opencode/releases> (v1.18.32, 2026-09-21, with `opencode-darwin-arm64.zip`, `-darwin-x64.zip` and `-darwin-x64-baseline.zip`, each with a SHA-256 digest).
  - The name collision: <https://github.com/opencode-ai/opencode> (archived; continues as <https://github.com/charmbracelet/crush>).
- **Open questions that need a real binary**, measured in planning on a scratch home (never the real one, never the vendor's script against the real home: memory "Vendor scripts touch the real home"):
  - Does the app today tell a runtime it supports `terminal-auth`? The app reads Copilot's `_meta.terminal-auth` from an auth method, but OpenCode adds that only when the client advertises `clientCapabilities._meta["terminal-auth"]`. Without it the sheet has only OpenCode's description text, and the command must come from the catalog.
  - How exactly the "not signed in" failure arrives: on `session/new` or on the first `session/prompt`.
  - Does OpenCode need any provider at all before `session/new` succeeds, and is there a model that works signed out?
  - Which tool ids `tools`/`permission` in inline config can remove (`task`, `todowrite`, the plan tools), and whether any come back through a custom agent.
  - Whether `autoupdate: false` in inline config is enough to stop self-update under ACP.
  - The oldest OpenCode release whose `acp` behaves as described, for FR-003's check, and how long the archived Go binary takes to fail when started with `acp`.
  - Whether the macOS release program runs without a Gatekeeper prompt when installed by the script (it is unzipped by `curl` and `unzip`, not a browser, so it carries no quarantine flag).
  - Where Homebrew's `anomalyco/tap/opencode` and npm's `opencode-ai` put the program. Both are usually on the login PATH already; the plan checks this.
- **Builds on 048** (the set-up page and vendor-script installs, merged `ee64697`). OpenCode is the fourth script runtime after Grok, Copilot and Cursor, and the row, progress, failure sentences and "offered once" rule are 048's.
- **Beside 046 and 047.** Both add a runtime, a policy entry and docs rows. Whichever merges last takes the others' rows, and the runtime count in the docs is written from the catalog at that point.
- **Servers are out of scope** (D2). 043 is not changed.
- **The phone and iPad** start OpenCode agents through the Mac. Nothing OpenCode-specific runs on them.
