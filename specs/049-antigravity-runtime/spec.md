# Feature Specification: Google Antigravity as a Runtime

**Feature Branch**: `agents/speckit-specify-support-antigravity`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Add support for Antigravity CLI. If it supports ACP that is."

## Why this feature exists

Antigravity is Google's coding agent and the successor to Gemini CLI. Gemini CLI now turns away
individuals who sign in with a Google account, telling them to "migrate to Antigravity"
(measured on the Gemini lane, 2026-09-25). So a person whose only way into Google's models is
their Google account has no way to use them in this app. The Gemini runtime (046, on its own
lane) covers only people with an API key.

**Does Antigravity speak ACP? Yes, but not through the CLI.** Measured 2026-09-25:

- The `agy` CLI has no ACP mode and no flag for one. Google's own issue asking for it
  (google-antigravity/antigravity-cli#31) is open.
- Google publishes a separate, official **Antigravity ACP server** (`agy_acp_server`, 1.2.1),
  listed in the ACP registry as `antigravity-acp`. It is a download from Google for the Mac
  (Apple silicon and Intel) and Linux (x86_64 and arm64), under Google's proprietary terms. It
  needs no `agy` CLI.
- It has its own sign-in, separate from `agy`'s. It offers a Google account (personal or
  business), a Gemini API key, or Google's Agent Platform. The first Google-account sign-in is
  a browser sign-in.
- Google's terms for Antigravity call using third-party tools with an Antigravity Google
  sign-in a breach. This app reaches Antigravity only through Google's own server, which Google
  publishes for ACP clients, but the risk is the person's to take, so the app says so (D3).

So Antigravity can be added the way the other runtimes are, as long as the app runs Google's ACP
server and not the CLI. **This feature makes Antigravity a runtime like the others, on the Mac
and on servers**, and it is the one Google runtime that a Google account alone can sign in to.

## Defaults taken *(Alex to confirm or overturn)*

Alex settled D1–D3 on 2026-09-25. The rest are defaults so that the spec is complete, and each
is marked *(default Dn)* where it is used.

- **D1. Its own runtime, beside Gemini.** Antigravity is a separate entry in the runtime list
  and a separate row on the set-up page. It does not replace Gemini (046) and is not merged into
  it. Gemini stays the runtime for API-key users, and Antigravity is the one for Google-account
  users. Either works without the other. *(Settled by Alex.)*
- **D2. On the Mac and on servers.** Servers get Antigravity the way 043 gives them Claude:
  the pinned Linux build installed on demand, and a credential from the Mac's Settings lent to
  each run. *(Settled by Alex.)* For Antigravity that credential is the Mac's Google sign-in,
  copied (D8), which has to be on the server's disk for the length of a run.
- **D3. A Google account, and nothing else.** Antigravity signs in with the person's Google
  account (personal or Workspace) through its own browser sign-in, which the app offers from
  the runtime sign-in sheet. The key and Agent Platform choices that Google's server also
  offers are not shown. A browser sign-in cannot happen on a server, so servers use the Mac's
  sign-in, copied (D8). The sign-in sheet quotes Antigravity's terms on third-party tools beside
  the Google choices and links to them, so the person decides with that in front of them.
  *(Settled by Alex, 2026-09-25, after reading the terms; "Google only" 2026-09-26.)*
- **D4. Installed from the set-up page, the app's own copy only.** Antigravity is a row on
  048's set-up page. **Install** downloads the pinned Antigravity ACP server from Google into
  the app's own folder and checks it against a checksum the app carries. The app never ships
  Google's program itself: the terms are Google's. An `agy` or Antigravity app the person
  installed is never used, changed or removed.
- **D5. Pinned.** Each app version names one Antigravity ACP server version, the same on the
  Mac and on servers. A newer app offers the newer version as an update, and a running agent
  keeps the build it started on until it ends.
- **D6. The Gemini key is Gemini's.** The Gemini API key in Settings ▸ Runtime credentials
  (046) is never lent to Antigravity, and Antigravity has no key of its own. *(Settled by Alex,
  2026-09-26: "Don't share the key. I think we'll see Gemini CLI get retired some time soon.")*
  If Gemini CLI is retired, the key may move to Antigravity then, as a spec of its own.
- **D7. The app's Antigravity keeps to the app's folder.** Antigravity's server keeps its
  settings, conversations and sign-in state in a folder of the app's own, not in `~/.gemini`,
  so nothing of the person's is read or written, and their own Antigravity set-up (skills,
  hooks, MCP servers) does not load in the app's agents. Google's server supports this for
  apps that embed it. Its Google sign-in is a private file in that folder too (D8), not a
  Keychain item. One exception, Google's and never read by the app: the
  video encoder Google's harness installs in `~/.gemini/antigravity/bin/` through `$HOME`
  (measured 2026-09-25). Moving `$HOME` for the process would move it too, but would also
  take the person's git and ssh set-up away from the agent's own commands.

- **D8. A server uses the Mac's Google sign-in, copied.**
  When the Mac has signed Antigravity in with Google, an Antigravity agent on a server signs in
  as the same account: the app copies the Mac's sign-in into that server's Antigravity folder
  when a run starts and removes it when the last Antigravity run on that server ends. With no
  Mac sign-in, a server agent asks for the Mac to be signed in first (D6). To make the copy
  possible without a Keychain prompt, the app's own Antigravity on the Mac keeps its sign-in in
  a private file in the app's folder rather than in the Keychain. The costs, written down so
  they are chosen and not stumbled on: the sign-in is on the server's disk while a run is
  going; the server may refresh it and the two copies may drift, in which case one of them asks
  to be signed in again; and moving a Google sign-in to another machine is closer to what
  Antigravity's terms name than anything else here, so the sheet's terms line covers it.
  *(Settled by Alex, 2026-09-25: "copy the local key to the remote machine" rather than an API
  key.)*

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start an Antigravity agent on the Mac with a Google account (Priority: P1)

The person uses Google's models through their Google account and has nothing of Google's
installed. The first time they open this version of the app, the set-up page lists
**Antigravity** as **Not on this Mac**, with **Install** and a note that it is a large download
from Google. One click starts the download, the row shows its progress, and then it is ticked.
In the start form, Antigravity is in the runtime list. They choose it and type a prompt. The
agent says Antigravity needs signing in and offers **Sign in with Google**. A browser opens,
they sign in, and the turn goes ahead. From then on Antigravity works like any other runtime:
it replies as it thinks, calls tools, asks permission, shows the diffs of the files it changes,
reports usage as far as it says it, can be stopped mid-turn, and can be resumed later with its
history.

**Why this priority**: It is the request, and it is what Gemini can no longer do for these people.

**Independent Test**: On a Mac with nothing of Google’s installed,
install Antigravity from the set-up page, start an agent, sign in with a Google account, and
ask it to create a file and run `ls`. The reply streams in, the tool calls show, the file
appears in the changes, and a later resume continues the conversation.

**Acceptance Scenarios**:

1. **Given** a Mac without the app's Antigravity, **When** the app starts, **Then** the set-up page lists Antigravity as not on this Mac with **Install**, once, even if the person dismissed the page before for other agents. The same row is in Settings ▸ Agents from then on.
2. **Given** Antigravity's row, **When** the person presses **Install**, **Then** the row shows the download's progress as a share of its size and a tick when done. A failure says why, with **Retry** and **Open install page**.
3. **Given** an `agy` CLI or the Antigravity app of the person's own, **When** the set-up page is shown, **Then** Antigravity still reads **Not on this Mac** until the app's copy is installed, and the person's copy is neither used nor changed *(default D4)*.
4. **Given** Antigravity installed and never signed in, **When** the person starts an agent, **Then** it says Antigravity needs signing in and offers **Sign in with Google**, which opens the browser. When sign-in completes, the waiting prompt goes ahead without being retyped *(D3)*.
5. **Given** Antigravity signed in once, **When** the person starts another agent later, **Then** no sign-in is asked for.
6. **Given** a running Antigravity agent, **When** it edits files, runs commands or asks permission, **Then** each shows in the conversation the way the same act from another runtime does, and a permission ask can be answered on the Mac or the phone.
7. **Given** an Antigravity agent mid-turn, **When** the person stops it, **Then** the turn ends and the agent can be given a new prompt.
8. **Given** a stopped or parked Antigravity agent, **When** the person resumes it, **Then** it continues the same conversation with its history.
9. **Given** a running Antigravity agent, **When** a newer build is installed, **Then** that agent is not interrupted and keeps its build until it ends *(default D5)*.

---

### User Story 2 - The sign-in sheet (Priority: P2)

The person opens **Sign in, sign out, providers…** for Antigravity. The sheet shows where it
stands (**Signed in and ready**, **Installed, and needs signing in**, or **Not installed**) and
two choices: a personal Google account and a Workspace (business) account, with Google's terms
line beside them. The key and Agent Platform choices Google's server also offers are not there
(D3, D6).

**Why this priority**: Sign-in is the step most likely to go wrong for a first-time user.

**Independent Test**: With Antigravity never signed in, open the sheet: two Google choices and
the terms line, nothing else. Sign in with Google, then sign out: the next start asks again.

**Acceptance Scenarios**:

1. **Given** the sign-in sheet for Antigravity, **When** it opens, **Then** it shows Antigravity's status and its own sign-in choices, with its own advice under each.
2. **Given** a Gemini key in Settings, **When** an Antigravity agent starts, **Then** the key is not used, and Antigravity still asks for a Google sign-in if it has none *(D6)*.
3. **Given** a Google sign-in that the person abandons or that fails in the browser, **When** they return to the app, **Then** the agent says sign-in did not complete, with **Try again**, and does not wait forever.
4. **Given** Antigravity signed in, **When** the person signs it out from the sheet, **Then** the next start asks for sign-in again, if Antigravity offers sign-out over ACP. If it doesn't, the sheet shows no sign-out button, as for Cursor.

---

### User Story 3 - The app's own tools and scoping (Priority: P2)

An Antigravity agent works inside the app the way a Claude agent does:

- It has the app's tools. It ends its turn with a report, asks questions, leases resources,
  waits for events, and starts and runs workflows.
- Antigravity's own tools that duplicate the app's are removed for the conversations the app
  starts, so its work stays where the app can see it. Any that cannot be removed are named as
  residue.
- A question it asks mid-turn reaches the person as a card, if Antigravity can ask over ACP.
  If it can't, the agent ends its turn with the question and shows **Waiting on your answer**.

**Why this priority**: Without this, Antigravity runs outside the app's rules. The runtime
policy table must also cover every runtime or a test fails, so this ships with P1.

**Independent Test**: Start an Antigravity agent and ask it to list its tools. The app's are
listed and the removed ones are not. Ask it to end with a report, lease a resource and ask a
question. Each arrives as it does for Claude.

**Acceptance Scenarios**:

1. **Given** an Antigravity agent, **When** it starts, **Then** it is given the app's tools and the same briefing as other runtimes.
2. **Given** Antigravity's own tools that overlap the app's (scheduling, starting other agents, notifications, saving documents elsewhere), **When** the app starts an agent, **Then** those are removed, or, where they can't be, named as residue in the policy and the briefing.
3. **Given** an Antigravity agent that needs an answer mid-turn, **When** it asks, **Then** the person sees a question card, or, failing that, **Waiting on your answer** with the question.

---

### User Story 4 - Antigravity on servers (Priority: P3)

The person has a Linux server added as in 043, and has signed Antigravity in with Google on the
Mac. When they start an Antigravity agent in a project on that server, the server downloads the
pinned Antigravity ACP server for Linux the first time, with progress in the set-up checklist.
The agent signs in as the same Google account, copied from the Mac for the run (D8). Someone who
never signed in with Google on the Mac is asked to, on the Mac, first.

**Why this priority**: It extends 043 to Antigravity. That matters for servers, but the Mac comes
first, and a server can only use a sign-in the Mac already has.

**Independent Test**: With Antigravity signed in with Google on the Mac and a bare x86_64 Linux
server, start an Antigravity agent in a server project and ask it to run `uname -a`. The reply
comes back. After the run, the copied sign-in is gone from the server's disk.

**Acceptance Scenarios**:

1. **Given** a server without Antigravity, **When** it is first needed there, **Then** the server downloads the pinned build for its platform, checks it against the app's checksum, and shows progress. A failed install names its cause and leaves nothing half-installed *(D2, default D5)*.
2. **Given** Antigravity signed in with Google on the Mac, **When** an Antigravity agent starts on a server, **Then** the Mac's sign-in is copied into that server's Antigravity folder (readable by its owner only) before the run, is in no log or transcript, and is removed when the last Antigravity run on that server ends *(D8)*.
2b. **Given** a copied sign-in that Google refuses, or that the Mac has since signed out of, **When** a server run starts, **Then** the agent says the Mac's sign-in needs renewing, with a way to do it on the Mac, and never opens a browser on the server.
3. **Given** no Mac sign-in, **When** the person starts an Antigravity agent on a server, **Then** the app asks for the Mac to be signed in with Google first, and starts nothing on the server until it is *(D3, D8)*.
4. **Given** a server marked "use this server's own sign-in only" (043), **When** an Antigravity agent starts there, **Then** nothing is copied, and Antigravity's own sign-in on the server is used.
5. **Given** a Linux arm64 server, **When** Antigravity is offered there, **Then** the app says whether the pinned build is known to work on that platform, and never starts an agent that crashes at launch without saying why.

---

### Everywhere a runtime is chosen

Antigravity is offered wherever another runtime is: a workflow's steps, the phone and iPad start
forms, the runtime menu above the prompt, and `start_agent` from another agent. On a server
project it is offered when it is installed there or can be installed there.

### Edge Cases

- **Not installed.** Choosing Antigravity says it is not on this Mac and offers the row's **Install**. It never starts and then fails.
- **Large download.** The server is 112 MB to download on the Mac (about 400 MB unpacked) and over 300 MB on Linux. The row says so before the download starts, shows progress, survives the app being quit mid-download (the next **Install** starts again or resumes), and says in a sentence if the disk is too full.
- **Install fails.** Offline, a checksum mismatch, or Google's download refused: the row says which, with **Retry** and **Open install page**. Nothing half-installed is ever used.
- **Slow first start.** Antigravity's server is slow to start the first time. The agent shows that it is starting, not a blank or a stall, and a start that takes longer than the app's limit ends with that reason.
- **Google changes or withdraws the server.** A pinned version that Google no longer serves shows as an install failure naming the version. A server that no longer speaks ACP the way the app expects ends with a sentence naming its version, never a hang.
- **Sign-in abandoned.** See User Story 2, scenario 3.
- **Quota or rate limit.** The turn ends with that reason in a sentence, and the agent can be prompted again later.
- **A Workspace account that its admin has not allowed.** The agent shows Google's refusal in words, with a way to sign in with another account.
- **Gemini and Antigravity both installed.** Each is its own runtime, signed in its own way: Gemini with its key, Antigravity with Google. Signing one in or out does nothing to the other *(D6)*.
- **The person's own `agy` or Antigravity app.** Neither is used or changed. Their sign-ins are not read *(default D4, D7)*.

## Requirements *(mandatory)*

### Functional Requirements

**Starting Antigravity on the Mac**

- **FR-001**: The app MUST list Antigravity among the runtimes it can start, everywhere a runtime is chosen: the Mac's start form and runtime menu, the phone and iPad start forms, workflow steps, and `start_agent`.
- **FR-002**: The app MUST run Google's official Antigravity ACP server for Antigravity agents, not the `agy` CLI.
- **FR-003**: Antigravity MUST have a row on the set-up page whose **Install** downloads the pinned server for this Mac's processor from Google into the app's own folder, checked against a checksum the app carries, with the download's size shown before it starts and its progress while it runs. The app MUST NOT include Google's program in its own download *(default D4)*.
- **FR-004**: Agents MUST run only the app's copy. An `agy` or Antigravity app the person installed MUST NOT be used, changed or removed, and MUST NOT make the row read as installed *(default D4)*.
- **FR-005**: Starting an Antigravity agent when it is not installed, still installing, or failed to install MUST say which and offer the row's action.
- **FR-006**: A running agent MUST keep the build it started on when a newer one is installed *(default D5)*.
- **FR-007**: An Antigravity agent MUST show replies, tool calls, permission asks, file changes, stop and resume the way the app shows them for other runtimes, limited only by what Antigravity reports over ACP.
- **FR-008**: Usage and cost MUST be shown where Antigravity reports them, and left out (not shown as zero) where it doesn't.
- **FR-009**: What Antigravity can do in the app (pictures, sign-in methods, sign-out, resume, model choice) MUST follow what it says about itself when it starts, not a list kept by the app.

**Signing in**

- **FR-010**: On the Mac, an Antigravity agent that cannot start because it is not signed in MUST say so and offer the Google sign-in. Completing the sign-in in the browser MUST let the waiting prompt go ahead. Abandoning it MUST end with a sentence and **Try again**, never an endless wait *(D3)*.
- **FR-011**: The sign-in sheet MUST show Antigravity's status and only its Google sign-in choices (personal and Workspace), and hand over a browser step where it needs one *(D3)*.
- **FR-012**: The Gemini API key in Settings MUST NOT be lent to Antigravity, and a key in the daemon's own environment MUST NOT reach it *(D6)*.
- **FR-013**: Antigravity agents MUST keep their settings, conversations and sign-in state in the app's own folder. The app MUST NOT read or write `~/.gemini`, and MUST NOT reuse the sign-ins of the person's own `agy` or Antigravity app *(default D7)*.

**The app's tools and scoping**

- **FR-014**: An Antigravity agent MUST be given the app's tools and the same briefing as other runtimes.
- **FR-015**: The runtime tool policy MUST have an entry for Antigravity that removes its tools duplicating the app's and names as residue any that can't be removed. The policy MUST still cover every runtime in the catalog.
- **FR-016**: A mid-turn question MUST reach the person as a card if Antigravity can ask over ACP, and otherwise as **Waiting on your answer** with the question.

**Antigravity on servers**

- **FR-017**: A server MUST download the pinned Linux build for its processor on demand from Google, checked against a checksum the app carries, with progress in the set-up checklist. An incomplete install MUST never be used *(D2, default D5)*.
- **FR-018**: On a server, Antigravity MUST be signed in with the Mac's Google sign-in, copied for the run. The copy MUST be written only into the server's own Antigravity folder, readable by its owner only, and removed when the last Antigravity run on that server ends, and it MUST NOT appear in any log, transcript or crash report. With no Mac sign-in the app MUST ask for one before starting anything on the server. No browser sign-in is offered on a server *(D3, D8)*.
- **FR-018a**: The app's own Antigravity on the Mac MUST keep its Google sign-in in a file in the app's folder, readable by its owner only, so the app can copy it without a Keychain prompt *(D8)*.
- **FR-019**: 043's rules for servers MUST hold for Antigravity where they apply: the "own sign-in only" mark, a refused sign-in as its own failure, and a rebuilt server set up again on confirmation.
- **FR-020**: On a server platform whose pinned build is known not to work, the app MUST say so before starting an agent there.

**Failures**

- **FR-021**: Not installed, a download that fails, a slow start past the limit, a server that no longer speaks ACP as expected, an abandoned sign-in, a quota or rate limit, and a refused key MUST each end with a sentence naming the cause, never an endless wait or "stopped answering".

### Key Entities

- **Antigravity runtime**: an entry in the app's runtime list: its name, how it is started (the app's copy of Google's Antigravity ACP server), how it is installed (a pinned download from Google, from the set-up page), and what it says about itself when it starts.
- **Antigravity build**: the pinned server version, with its download address and checksum for each platform (Mac Apple silicon and Intel; Linux x86_64 and arm64), and whether each is known to work.
- **Antigravity tool policy**: which of its tools are removed for the app's agents, which remain as residue and why, and how its questions reach the person.
- **Antigravity's sign-in**: the Google sign-in Antigravity's own server keeps as a private file in the app's Antigravity folder, copied to a server for a run (D8). Not a Settings credential.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Mac with nothing of Google's installed, a person with a Google account goes from pressing **Install** to an Antigravity agent's first reply within 10 minutes on a 100 Mbit/s connection, download included, having run no command.
- **SC-002**: Once installed and signed in, an Antigravity agent's first reply arrives no more than 10 seconds later than a Claude agent's on the same Mac.
- **SC-003**: Every failure in the edge cases above shows as a sentence naming its cause. None shows as an endless wait or as "stopped answering".
- **SC-004**: After a day of Antigravity agents in the app, the person's `~/.gemini` is byte for byte what it was before, apart from Google's own encoder in `~/.gemini/antigravity/bin/` (D7), and their own `agy` and Antigravity app are unchanged.
- **SC-005**: From a bare x86_64 Linux server, a person signed in with Google on the Mac gets an Antigravity agent's first reply within 10 minutes, having run no command on the server and signed in nowhere else. After the run ends, a search of the server's disk finds no copy of the sign-in, and the Mac's logs mention it nowhere.
- **SC-006**: An Antigravity agent's turns end with the app's outcome report in at least 9 of 10 turns, as measured for the other runtimes.

## Docs *(mandatory)*

- `docs/reference/runtimes.md` — change: add an Antigravity row (Google's ACP server, pictures, sign-in, app tools, questions, residue), and say how it differs from Gemini.
- `docs/how-to/sign-a-runtime-in.md` — change: Antigravity signs in with Google only, and the terms line.
- `docs/how-to/add-a-linux-server.md` — change: Antigravity on a server uses the Mac's Google sign-in, and which platforms work.

## Assumptions

- The handshake was measured on this Mac on 2026-09-25 (research R3). A real turn, the Google sign-in and Linux still need measuring. They are Phase 0 of the plan.
- Antigravity's terms (https://antigravity.google/terms) call "using third party software, tools, or services to access the Service (e.g. using OpenClaw with Antigravity OAuth)" a breach. Alex decided on 2026-09-25 to keep the Google-account sign-in anyway, because Google's own ACP server does it and the app never touches the token. The sign-in sheet quotes that line and links to the terms (D3). The app downloads the server from Google on the person's machine and never redistributes it.
- Measured 2026-09-25 (research R2, R8): the Mac download is 112 MB (399 MB unpacked), Linux's 321–334 MB, and a cold start takes 6–8 s. The Linux arm64 crash is reported upstream and not yet measured.
- **Builds on 048** (the set-up page and Mac toolset install, merged `ee64697`) and **043** (runtime credentials, server toolsets, "own sign-in only").
- The spec number 049 follows 046 (Gemini), 047 (Codex) and 048 (set-up page). The Gemini lane's own spec number collides with main's 046 and will be renumbered when it merges; this spec refers to it as "046 Gemini".
