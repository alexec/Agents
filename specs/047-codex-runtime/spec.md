# Feature Specification: Codex as a Runtime

**Feature Branch**: `agents/speckit-specify-support-codex`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "support for Codex"

## Why this feature exists

The app starts four runtimes (Claude, Grok, Copilot and Cursor), and 046 specifies Gemini as a
fifth. Codex is OpenAI's coding agent, and many people already pay for it through their
ChatGPT plan. Right now they can only use it in a terminal or its own app next to this one, and
none of that work shows up in the app's lists, on the phone, in workflows or in leases. 036
recorded this plainly: "Codex isn't a runtime."

Codex does not speak the agent protocol (ACP) on its own. Its ACP adapter, published by the
same project that publishes Claude's, is a Node package that carries Codex's own program for
each platform. So the app can install it the way it installs Claude for somebody without Node:
a pinned Node and the adapter, in the app's own folder. The person needs nothing on their Mac
beforehand. How the app installs its runtimes' programs at start-up is a separate feature
(048, now merged). This spec needs Codex to be one of the
programs it installs, and says what Codex needs from it. The work here is in
the parts that differ between runtimes: how Codex signs in (a ChatGPT account, with a refresh
token Codex keeps rotating), its own approval and sandbox presets, which of its tools overlap
with the app's, how it asks questions, and how it gets onto a server.

**This feature makes Codex a runtime like the others**, on the Mac and on servers, and the app
installs it itself on both. On the Mac it signs in with the person's ChatGPT account. Servers
sign in with an OpenAI API key lent from the Mac.

## Defaults taken *(Alex to confirm or overturn)*

Alex settled D1, D2, D3 and D4 on 2026-09-25. The rest are defaults so that the spec is complete,
and each is marked *(default Dn)* where it is used.

- **D1. On the Mac, a ChatGPT account is the normal way in.** Codex's own sign-in in the
  person's home is what an agent on the Mac uses. A ChatGPT account is the way the app offers
  first, and an OpenAI API key is the other way. *(Settled by Alex.)*
- **D2. On the Mac and on servers.** Servers get Codex the way 043 gives them Claude: a pinned
  toolset installed on demand, and a credential lent to each run and never written to the
  server's disk. *(Settled by Alex.)*
- **D3. The app installs Codex itself, through the start-up installer.** Codex's ACP adapter,
  pinned, for this machine's platform, is one of the programs the app's start-up installer
  fetches, checks and keeps up to date. That installer is its own feature, planned in another
  lane. This spec does not define how it downloads, verifies, updates or reports progress. It
  only requires that Codex is covered, and that nothing else is needed: no Node, no npm, no
  `codex` on the PATH. The app never uses or replaces a `codex` the person installed themselves.
  Servers get the Linux build through 043's toolset in the same way (D2). *(Settled by Alex.)*
- **D4. A server's credential is an OpenAI API key.** Settings takes an OpenAI API key for
  servers only. A ChatGPT sign-in is not copied to servers. It is a refresh token that Codex
  rotates as it uses it, so if the Mac and a server used it at once, each would sign the other
  out. Server turns are billed per token to the key's OpenAI account, not to the ChatGPT plan.
  *(Settled by Alex.)*
- **D5. Pinned, and moved on by the installer.** Each app version names one Codex version.
  Updating it is the start-up installer's job, under its rules. The one rule Codex adds is that
  a running Codex agent keeps the build it started on.
- **D6. The person's own Codex settings are left alone.** The app does not edit
  `~/.codex/config.toml`, the sign-in in `~/.codex`, or any other file of Codex's in the
  person's home. It does not point Codex at a home of its own either, because that would sign
  the person out of their own (the reason Cursor has no lever). Anything the app sets for its
  own agents (its tools, which of Codex's tools are removed, the approval preset) is passed
  when it starts that agent, and holds for that agent only.
- **D7. Codex's approval and sandbox presets are the agent's modes.** Codex's presets (for
  example read-only, asking before acting, full access) show as the agent's modes, the way
  Claude's permission modes do. The app remembers the last one picked for Codex, and a helper
  started by a Codex agent inherits it, as the other runtimes do.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a Codex agent on the Mac (Priority: P1)

The person has never installed Codex, or has Codex of their own signed in with their ChatGPT
account. In the start form, **Codex** is in the runtime list beside the others. They choose it
and type a prompt. Codex is already there, because the app installed it when it started. If
that install is still running or has failed, the agent says so, not that it hangs. Then Codex
works like any other runtime: it replies as it thinks, calls tools, asks permission where its preset says to, shows
the diffs of the files it changes, reports usage as far as Codex says it, can be stopped
mid-turn, and can be resumed later with its history.

**Why this priority**: It is the request. Without it the other stories have nothing to act on.

**Independent Test**: On a Mac with no Codex, Node or npm installed, and a ChatGPT sign-in in
`~/.codex`, start a Codex agent in a project and ask it to create a file and run `ls`. The reply streams in, the
tool calls show, the file appears in the changes, and a later resume continues the conversation.

**Acceptance Scenarios**:

1. **Given** the start form, **When** the person opens the runtime list, **Then** Codex is listed with the other runtimes, and a new conversation can be started with it *(default D3)*.
2. **Given** a Mac that has never had Codex, **When** the app starts, **Then** Codex is installed along with the app's other runtimes, and a Codex agent started afterwards needs nothing from the person *(default D3)*.
3. **Given** a Codex agent started while the start-up install is still running, or after it failed, **When** it starts, **Then** it says Codex is still being installed, or why the install failed, and it is never left waiting silently *(default D3)*.
4. **Given** a running Codex agent, **When** the installer moves Codex to a newer build, **Then** that agent is not interrupted and keeps its build until it ends *(default D5)*.
5. **Given** a running Codex agent, **When** it edits files, runs commands or asks permission, **Then** each shows in the conversation the way the same act from another runtime does, and a permission ask can be answered on the Mac or the phone.
6. **Given** a Codex agent mid-turn, **When** the person stops it, **Then** the turn ends and the agent can be given a new prompt.
7. **Given** a stopped or parked Codex agent, **When** the person resumes it, **Then** it continues the same conversation with its history if Codex supports loading a conversation. If it does not, the app says that resume starts afresh and does not claim otherwise.
8. **Given** the modes menu for a Codex agent, **When** the person opens it, **Then** it lists Codex's own approval presets. The one picked applies from the next action, and it is remembered for the next Codex agent *(default D7)*.
9. **Given** the model menu for a Codex agent, **When** the person opens it, **Then** it lists the models and reasoning levels Codex offers, as the adapter reports them.

---

### User Story 2 - Sign Codex in with ChatGPT (Priority: P1)

The person starts a Codex agent without having signed Codex in. They do not get a silent failure
or an empty reply. The runtime menu says **Needs signing in** beside Codex, and **Sign in, sign
out, providers…** opens the same sheet the other runtimes use. It offers **Sign in with
ChatGPT** first and an OpenAI API key second, with Codex's own advice under each. Signing in
with ChatGPT opens the browser, and the sheet shows **Signed in and ready** once the browser
step is done.

**Why this priority**: Codex is not installed on the Mac this is built on, and most people
trying Codex here for the first time will not have it signed in. A start that fails without a
word would make Codex look broken. It ships with Story 1.

**Independent Test**: With no Codex sign-in in the Mac's home, start a Codex agent: the app
says it needs signing in and offers the sheet. Sign in with ChatGPT from the sheet. A new turn
works, and Codex in Terminal is signed in too.

**Acceptance Scenarios**:

1. **Given** Codex not signed in on the Mac, **When** the person starts a Codex agent, **Then** the agent says Codex needs signing in, with a way to do it, and never waits forever or shows only "stopped answering".
2. **Given** the sign-in sheet for Codex, **When** it opens, **Then** it shows where Codex stands (**Signed in and ready**, **Installed, and needs signing in**, or **Not asked yet**) and Codex's sign-in choices, with ChatGPT first *(default D1)*.
3. **Given** **Sign in with ChatGPT**, **When** the person picks it, **Then** the browser opens at OpenAI's sign-in. If Codex can only complete it from a terminal, the app hands over the exact command with **Open Terminal** and **Copy**, as it does for Copilot.
4. **Given** Codex signed in on the Mac, **When** an agent starts, **Then** it uses that sign-in, which is the same one Codex uses in Terminal, and the app writes no sign-in of its own *(default D6)*.
5. **Given** Codex signed in, **When** the person signs it out from the sheet, **Then** the next start says it needs signing in again, if Codex offers a way to sign out over ACP. If it does not, the sheet shows no sign-out button, as for Cursor.
6. **Given** a ChatGPT plan that has reached its usage limit, **When** a Codex turn is refused for it, **Then** the turn ends with a sentence saying so, including when the limit resets if Codex says when.

---

### User Story 3 - The app's own tools and scoping (Priority: P2)

A Codex agent works inside the app the way a Claude agent does. It has the app's tools: it ends
its turn with a report, asks questions, leases resources, waits for events, starts helpers, and
starts and runs workflows. Codex's own tools that duplicate the app's are taken away for the
conversations the app starts. Where one cannot be taken away, it is named as residue, the way
three of Cursor's are. When a Codex agent needs to ask the person something mid-turn, the
question reaches the person as a card if Codex has a way to ask over ACP. If it does not, it
ends its turn with the question, and the agent shows **Waiting on your answer**, as Grok does.

**Why this priority**: Without it Codex runs, but outside the app's rules: its turns end
without a report, and it cannot lease or wait. The runtime policy table must cover every
runtime in the catalog, or a test fails, so this story has to ship alongside Story 1 before
Codex is offered.

**Independent Test**: Start a Codex agent and ask it to list the tools it has. The app's tools
are listed and the removed ones are not. Ask it to end its turn with a report, to lease a
resource and to ask a question. Each arrives in the app as it does for Claude.

**Acceptance Scenarios**:

1. **Given** a Codex agent, **When** it starts, **Then** it is given the app's tools and the same briefing as other runtimes.
2. **Given** a Codex agent, **When** it ends a turn, **Then** it reports the turn's outcome through the app's tool, as Claude does.
3. **Given** Codex's own tools that overlap with the app's (anything that schedules, starts other agents, notifies or saves documents elsewhere), **When** the app starts a Codex agent, **Then** those are removed. Where they cannot be removed, they are named as residue in the policy and in the briefing.
4. **Given** a Codex agent that needs an answer mid-turn, **When** it asks, **Then** the person sees a question card if Codex can ask over ACP, or otherwise the agent shows **Waiting on your answer** with the question.
5. **Given** the app's tools reach Codex, **When** Codex's own approval preset would ask before running one of them, **Then** the app's tools are not held behind Codex's approval, or, where the adapter gives no way to exempt them, the plan records which tools ask and the briefing does not promise otherwise.
6. **Given** the same Codex started from Terminal, **When** the person uses it there, **Then** it has every tool and setting it always had, and the app has changed none of them *(default D6)*.

---

### User Story 4 - Codex on servers (Priority: P3)

The person has a bare Linux server added as in 043, and an OpenAI API key in Settings. When they
start a Codex agent in a project on that server, the server installs Codex's pinned toolset the
first time, with its progress in the set-up checklist. The agent then signs in with the key lent
from the Mac. The key is never written to the server's disk. The Mac's own Codex agents keep
using the ChatGPT account.

**Why this priority**: It extends 043 to Codex. That matters for the ephemeral servers 043 is
about, but the Mac comes first.

**Independent Test**: With an OpenAI API key in Settings and a Linux server with nothing on it,
start a Codex agent in a server project and ask it to run `uname -a`. The reply comes back.
Afterwards, a search of the server's disk finds the key nowhere, and Codex on the Mac is still
signed in with ChatGPT.

**Acceptance Scenarios**:

1. **Given** Settings' runtime credentials, **When** the person opens them, **Then** Codex is listed beside the others, with the kind of key it takes (an OpenAI API key), where to get one, a note that server turns are billed to that key and not to the ChatGPT plan, and a field to paste it *(default D4)*.
2. **Given** a pasted OpenAI key, **When** it is saved, **Then** the app checks it with OpenAI, says in words whether it works, and keeps it only in the Mac's Keychain.
3. **Given** a server without Codex, **When** Codex is first needed there, **Then** the server installs the pinned toolset, checks it against the app's checksums, and shows its progress. A failed install names its cause and leaves nothing half-installed *(default D2, D5)*.
4. **Given** a Codex agent starting on a server, **When** it signs in, **Then** the key reaches that run only. It is not written to the server's disk, any log or any transcript, and it is not sent to a server for any other runtime.
5. **Given** a server marked "use this server's own sign-in only" (043), **When** a Codex agent starts there, **Then** no key is sent, and Codex's own sign-in on the server is used.
6. **Given** no OpenAI key in Settings and no sign-in on the server, **When** the person starts a Codex agent there, **Then** the app asks for the key in place before starting. It never copies the Mac's ChatGPT sign-in.

---

### Everywhere a runtime is chosen

Codex is offered wherever another runtime is: a workflow's steps, the phone's and iPad's start
forms, the runtime menu above the prompt, and `start_agent` from another agent. On a server
project it is offered when it is installed there, or can be installed there (User Story 4).

### Edge Cases

- **Codex not installed yet.** A download that fails, a download that does not match, or being offline when the app starts are the installer's to handle. Codex's part is to say, when an agent is started, which of these happened, and never to show "stopped answering" instead.
- **The person has their own Codex.** A `codex` the person installed, through npm, Homebrew or OpenAI's app, is left alone: not used, updated or removed. It shares only the sign-in in `~/.codex`, which is what lets a ChatGPT sign-in made in either place work in both *(default D3, D6)*.
- **An unsupported Mac.** If the pinned release has no build for this Mac's architecture or macOS version, Codex is shown as unavailable, with the reason, and it is not offered in the start form.
- **A Codex or adapter release changes how ACP starts, or drops it.** The agent says Codex did not start in a mode the app can talk to, and names the version. It does not hang. The plan's research records what was measured, and a check script can measure it again.
- **The sign-in expires or is revoked mid-session.** Codex refreshes its own token. If that fails (for example, the person signed out elsewhere), the turn ends with a sentence saying Codex needs signing in again, and the sheet can be opened from there.
- **A key in the environment.** On the Mac, `OPENAI_API_KEY` or `CODEX_API_KEY` in the environment the app was launched with is Codex's own business, and Codex decides which sign-in wins; the app neither adds nor strips one. On a server, the key from Settings replaces any key in the server's environment for that run (043 D1).
- **A ChatGPT plan limit, or an API rate limit.** The turn ends with the reason in a sentence, not as a crash, and the agent can be prompted again later.
- **Usage without money.** A ChatGPT-plan turn reports tokens but no dollar cost. The app shows the tokens and no cost, never a cost of zero. An API-key turn on a server shows cost where Codex reports it.
- **Codex's own sandbox refuses an action.** A command blocked by Codex's sandbox shows as a failed tool call with Codex's reason. The app does not present it as its own refusal, or as an app error.
- **The person's own Codex settings.** `~/.codex/config.toml`, its MCP servers and its profiles are never written by the app. Whether Codex loads the person's MCP servers in the app's agents is recorded in the plan's research *(default D6)*.
- **A key OpenAI refuses.** The agent stops with a sentence saying the key was refused, with a way to replace it, and this reads differently from any other failure (043 FR-016).
- **Attachments.** A picture attached for a Codex agent goes as a picture if Codex says it takes pictures, and as a reference to the file if not.

## Requirements *(mandatory)*

### Functional Requirements

**Starting Codex on the Mac**

- **FR-001**: The app MUST list Codex among the runtimes it can start, everywhere a runtime is chosen: the Mac's start form and runtime menu, the phone and iPad start forms, workflow steps, and `start_agent`.
- **FR-002**: Codex's pinned ACP adapter build MUST be one of the programs the app's start-up installer installs on the Mac, for the Mac's architecture. Codex MUST need nothing installed beforehand (no Node, npm or `codex`), and the app MUST NOT use, change or remove a Codex the person installed themselves *(default D3)*.
- **FR-003**: A Codex agent started before Codex is installed MUST say whether the install is still running or why it failed, in a sentence, and MUST NOT wait silently or show "stopped answering".
- **FR-003a**: A running Codex agent MUST keep the build it started on when the installer moves Codex to a newer one *(default D5)*.
- **FR-004**: A Codex agent MUST show replies, tool calls, permission asks, file changes, stop and resume the way the app shows them for other runtimes, limited only by what Codex reports over ACP.
- **FR-005**: Token usage MUST be shown where Codex reports it. Cost MUST be shown only where Codex reports a cost, and left out (never shown as zero) where it does not.
- **FR-006**: Codex's approval presets MUST show as the agent's modes, and its models as the model menu, both as the adapter reports them. The last mode picked MUST be remembered for Codex, and helpers MUST inherit it as they do for other runtimes *(default D7)*.
- **FR-007**: What Codex can do in the app (pictures, sign-in, sign-out, resume, modes, models) MUST follow what it says about itself when it starts, not a list kept by the app.

**Signing in**

- **FR-008**: A Codex agent that cannot start because Codex is not signed in MUST say so and offer the runtime sign-in sheet. It MUST NOT fail silently or wait forever.
- **FR-009**: The sign-in sheet MUST offer signing in with a ChatGPT account first and an OpenAI API key second, with Codex's own advice, and MUST hand over a browser or terminal step where Codex needs one *(default D1)*.
- **FR-010**: On the Mac, a Codex agent MUST use Codex's own sign-in in the person's home. The app MUST NOT keep a copy of it, and a key in Settings MUST NOT be sent to agents on the Mac.
- **FR-011**: A turn refused for a plan limit, a rate limit or an expired sign-in MUST end with a sentence naming which, including when it resets if Codex says when.

**The app's tools and scoping**

- **FR-012**: A Codex agent MUST be given the app's tools and the same briefing as other runtimes.
- **FR-013**: The runtime tool policy MUST have an entry for Codex. It removes Codex's tools that duplicate the app's (standing arrangements, starting agents, notifications, artefact stores) and names as residue any it cannot remove. The policy MUST cover every runtime in the catalog, and a test MUST say so.
- **FR-014**: A Codex agent's mid-turn question MUST reach the person as a card if Codex can ask over ACP, and otherwise as **Waiting on your answer** with the question.
- **FR-015**: The app's own tools MUST NOT be held behind Codex's approval prompts where the adapter allows exempting them. Where it does not, the briefing MUST NOT claim they run without asking.
- **FR-016**: The app MUST NOT write to `~/.codex` or point Codex at another home. Everything it sets for its own agents MUST be passed when it starts that agent *(default D6)*.

**Codex on servers**

- **FR-017**: Settings' runtime credentials MUST list Codex and take an OpenAI API key, with a note that server turns are billed to that key. The app MUST check the key with OpenAI on save, say in words whether it works, keep it only in the Mac's Keychain, and show it masked afterwards *(default D4)*.
- **FR-018**: A server MUST install Codex's pinned toolset on demand, from official sources, checked against checksums the app carries, with progress in the set-up checklist. An incomplete install MUST never be used *(default D2, D5)*.
- **FR-019**: An OpenAI key MUST reach a server only as part of starting Codex there, for that run. It MUST NOT be written to the server's disk, any log, transcript or crash report, or sent for any other runtime.
- **FR-020**: The Mac's ChatGPT sign-in MUST NOT be copied, lent or sent to any server.
- **FR-021**: 043's rules for servers MUST hold for Codex as they do for Claude: a server's "own sign-in only" mark, asking for the key in place when none is usable, a refused key shown as its own failure, and a rebuilt server set up again on confirmation.

**Failures**

- **FR-022**: Codex not installed (still running or failed), an unsupported Mac, a changed ACP mode, an expired sign-in, a plan or rate limit, and a refused key MUST each end with a sentence naming the cause, never an endless wait or "stopped answering".

### Key Entities

- **Codex runtime**: an entry in the app's runtime list: its name, how it is started (the app-installed build of its ACP adapter), and what it says about itself when it starts (sign-in methods, modes, models, pictures, resume).
- **Codex tool policy**: which of Codex's tools are removed for the app's agents, which remain as residue and why, how its questions reach the person, and whether the app's tools are exempt from its approval prompts.
- **Codex server credential**: an OpenAI API key, for servers only, kept in the Mac's Keychain, masked when shown, with when it was added and when it last worked. This is 043's runtime credential, gaining another kind.
- **Codex toolset**: the pinned build of the adapter (with the Codex it carries) for one machine's platform (macOS or Linux, x86-64 or ARM64). On the Mac it is an entry in the start-up installer's list. On a server it is one of 043's installed tools.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Mac with no Codex, Node or npm and no Codex sign-in, a person who has never used Codex gets a Codex agent's first reply within 3 minutes of choosing it, counting the ChatGPT sign-in (and the start-up install, if it has not finished), having typed no command and installed nothing.
- **SC-002**: A later Codex start, with Codex installed, takes no more than 5 seconds longer to reach its first reply than a Claude start on the same Mac.
- **SC-003**: Every failure in the edge cases above shows as a sentence naming its cause. None shows as an endless wait or as "stopped answering".
- **SC-004**: After a day of Codex agents in the app, the person's `~/.codex/config.toml` is byte for byte what it was before, and Codex in Terminal is still signed in with the same account.
- **SC-005**: From a bare Linux server, a person with an OpenAI key in Settings gets a Codex agent's first reply within 5 minutes, having run no command on the server. Afterwards, a search of the server's disk and the Mac's logs finds the key in neither, and finds no ChatGPT sign-in on the server.
- **SC-006**: A Codex agent's turns end with the app's outcome report in at least 9 of 10 turns, as measured for the other runtimes that have the app's tools.

## Docs *(mandatory)*

- `docs/reference/runtimes.md` — change: the runtime count, plus a Codex row (installed by the app, nothing to set up; pictures, sign-in, modes, app tools, notes on questions, plan limits and residue).
- `docs/how-to/sign-a-runtime-in.md` — change: name Codex among the runtimes, and add signing in with ChatGPT, or with an API key.
- `docs/how-to/add-a-linux-server.md` — change: Codex installs on a server as Claude does, it takes an OpenAI API key from Settings, and why a ChatGPT sign-in stays on the Mac.
- `docs/reference/settings.md` — change: the runtime credentials entry lists an OpenAI API key for Codex.
- `docs/explanation/scoped-tools.md` — change: add Codex's removed tools and its residue.

## Assumptions

- Codex is run through its ACP adapter (published as `@agentclientprotocol/codex-acp`, 1.13.1 on 2026-09-25), which carries Codex itself and ships a self-contained build per platform. The plan's research measures, against a real signed-in Codex rather than from this spec: where the official per-platform builds and their checksums are published, whether a build runs without Node, whether the Mac build is signed so it runs without a Gatekeeper prompt, the exact command, its sign-in methods over ACP, its modes and models, its tool names, whether it can ask a question or sign out over ACP, whether it loads a conversation, and how the app's MCP tools reach it. Codex is not installed on this Mac today, and Alex will sign it in with his ChatGPT account for the live proof.
- The adapter's release has builds for macOS (Apple silicon and Intel) and Linux (x86-64 and ARM64). Measured in planning: the adapter needs Node, so the installer installs a pinned Node beside it, as it does for Claude, and the person still installs nothing.
- **Depends on the start-up installer**, a separate feature being planned in another lane. That feature owns downloading, checking, updating, progress and failure reporting for the app's runtime programs on the Mac. This spec adds Codex to its list, and can be planned alongside it, but cannot ship on the Mac before it. Until the installer's spec exists, this plan must coordinate with that lane rather than build a Codex-only installer.
- Codex accepts an OpenAI API key through its environment, so a server can be signed in by lending the key per run, as 043 does for Claude.
- This builds on 043 (runtime credentials, server toolsets, "own sign-in only"), which is merged. It extends 043's D3 "Claude first" to Codex, as 046 does for Gemini. 046 and this spec both add a runtime, a policy entry and a toolset; whichever merges second takes the other's rows.
- The phone and iPad start Codex agents through the Mac. Nothing Codex-specific runs on them.
