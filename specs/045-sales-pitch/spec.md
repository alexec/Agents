# Feature Specification: Why Agents — the pitch

**Feature Branch**: `045-sales-pitch`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Compose the sales pitch. Why would you use this rather than other IDEs?"

## Why this feature exists

The docs site (044) is live at alexec.github.io/Agents and says what Agents is in two sentences: a
Mac app that runs the coding agents you already have and lets you follow them from your iPhone and iPad.
It never says why someone would choose it. A developer who lands there already has a coding agent they
like, usually inside an editor (Cursor, VS Code with Copilot, Windsurf, Zed), in a terminal (Claude Code,
Codex, Grok), or in someone's cloud (Copilot's coding agent, Codex in the cloud, Claude Code on the web).
Their question is "what do I get here that I don't get there?". Nothing on the site answers it.

The answer exists, but it is spread across 44 specs. Taken together they describe a different kind of
tool from an IDE. An IDE is built around one person editing files with one assistant beside them. Agents
is built around several agents working at once, while the person is often somewhere else:

- **It runs what you already have.** Claude, Grok, Copilot and Cursor, each with your own sign-in and
  plan. You can choose a different one for each agent. Agents does not add a model or a bill of its own.
- **Many agents, sorted by who needs you.** Every agent is in one of these groups: Needs attention,
  Blocked, Working, Complete, Stopped or Parked. Each one ends its turn with a sentence saying how it went,
  so you can see what needs doing without reading the conversations.
- **You see the work, not just the chat.** A document an agent writes opens beside the conversation
  and fills in as it writes, and you can type on it, on the Mac, the iPhone or the iPad. Code changes
  are coloured down to the word.
- **They work together, and they work on their own.** An IDE's assistant does what you ask, while you
  watch. Here, agents coordinate, and work starts without you:
  - **Leases**: agents take turns with anything only one of them should use at a time, such as the
    screen, a browser or a simulator. An agent that is in line ends its turn and costs nothing. It is
    started again when its turn comes. You can see who holds what and end a lease.
  - **Events and waiting**: an agent can wait for something to happen, such as checks passing on a
    pull request, another agent finishing, a branch moving or the Mac waking. It ends its turn, and it
    is woken with what happened. Agents can publish events of their own for each other. The Mac keeps a
    log of events, and the phone and iPad can read it.
  - **Workflows**: a Markdown file in the project starts an agent on a schedule or on an event, for
    example every weekday at nine, when an agent finishes, or when a pull request's checks fail. The
    file lives with the code.
  - **Pull requests watched to the end**: an agent fixes failing checks, answers review comments and
    resolves conflicts on your open pull requests.
  - **Agents that manage agents**: an agent can start up to three others, brief them, wait for them and
    stop them. Each can have a worktree of its own, so they do not edit the same files.
- **They keep going without you.** Agents run in a background helper, not in the window. Closing the
  window or quitting the app does not stop them. The Mac stays awake while a turn is in progress. After
  the Mac restarts, the agents that were working pick up where they stopped when you next open Agents.
- **You can follow them from anywhere.** On the iPhone and iPad you can read, answer, start, stop and
  attach. When an agent needs you and you are away from the Mac, a notification goes to the device you
  used last.
- **The work runs on your machines.** The work stays on your Mac, or on Linux servers you own, reached
  over SSH. On a server, Agents installs what Claude needs by itself, and your token stays in the
  Mac's Keychain. There is no cloud service of ours in between.
- **One figure for spending**, across every runtime and server.

This feature writes that case down once, honestly, on the public site. It also says where an editor or
a cloud agent is still the better choice.

**Gap to close first.** Events and waiting (042) are on main, but the docs site says nothing about
them. 042 was specified before specs had a Docs section. There is no page listing the events. The
workflow reference lists only the old nine trigger names, and the tools reference has no
`wait_for_event`, `cancel_wait` or `publish_event`. The pitch cannot claim what the docs do not show
(FR-008), so this feature also writes those pages (FR-016).

## Clarifications

### Session 2026-09-25

- Q: Where should the pitch live? → A: A "Why Agents" page in Explanation, with two lines on the home page
  and README linking to it (D1).
- Q: How should the pitch treat other tools? → A: By kind, with products named only as examples (D2).
- Q: Should the pitch say where another tool is better? → A: Yes, in its own section (D3).

Alex confirmed D1–D3 as written below. D4 is a default:

- **D1 (where it lives)**: one page on the docs site, "Why Agents", in the Explanation section,
  because Diataxis's Explanation section is for why. The home page and the README each open with a two-line
  version and link to it.
- **D2 (naming other tools)**: other tools are compared by kind: an agent inside an editor, an agent in a
  terminal, an agent in someone's cloud, and other apps that run several agents. Well-known products are
  named only as examples of each kind. There is no feature-by-feature scoreboard of named products,
  because it would go out of date the day one of them ships something and would be ours to keep correct.
- **D3 (honesty)**: the page has a "When something else is better" section. Agents is Mac-only and is
  built from source. It is not an editor. The phone reaches the Mac only on the same network. Copilot gets
  none of the app's tools.
- **D4 (reader)**: a developer who already uses at least one coding agent. Someone who has never used
  one is not the reader.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A developer who uses an agent in their editor sees why they would add Agents (Priority: P1)

A developer uses Cursor, or VS Code with Copilot, every day. A colleague sends them the docs site. On
the home page, in the first screen, they read in two lines what Agents is for and that it is not a new
editor. They follow "Why Agents" and within two minutes they know three things. First, they keep their
editor and their runtime. Second, Agents is where they run several agents at once and come back to what
needs them. Third, they can answer those agents from their phone. They also learn what they would give up,
and where to start.

**Why this priority**: This is the question the user asked, and the reader who asks it most often.
The page and the home-page lines are enough to publish on their own.

**Independent Test**: Give the page to three developers who use an agent in their editor. After two
minutes of reading, each one can give, in their own words, at least three reasons to use Agents and at
least one reason not to.

**Acceptance Scenarios**:

1. **Given** the docs home page, **When** a reader looks at the first screen without scrolling, **Then**
   they see a two-line statement of why to use Agents and a link to "Why Agents".
2. **Given** the "Why Agents" page, **When** a reader reads only its opening (the headline and the lines
   under it), **Then** they learn that Agents runs the agents they already have, several at once, and
   that they can follow those agents away from the desk.
3. **Given** the page, **When** a reader looks for how Agents differs from an agent in their editor,
   **Then** one section answers it directly and says that they keep their editor.
4. **Given** the page, **When** a reader reaches the end, **Then** one clearly marked link takes them to
   the first tutorial.

---

### User Story 2 - Every claim can be checked (Priority: P1)

A sceptical reader, or Alex before publishing, picks any claim on the page, such as "keeps working when
the window is closed", "answer from your phone" or "one spending figure". The claim links to the docs page
that shows how it works. The claim is true of the app as it is on main today.

**Why this priority**: A pitch that overclaims costs more trust than it earns, and this one is on a
public site next to the code. The claims must be true on the day of publishing and must stay true.

**Independent Test**: For each claim on the page, follow its link. The page it reaches describes that
behaviour. Walk the behaviour once on the current build and confirm it happens.

**Acceptance Scenarios**:

1. **Given** any claim of a capability on the page, **When** a reader follows it, **Then** it links to a
   how-to, reference or explanation page that describes that capability.
2. **Given** a capability with a known limit (for example, Copilot gets no app tools, or the phone
   reaches the Mac only on the local network), **When** the page claims that capability, **Then** the page
   states the limit next to the claim or in "When something else is better".
3. **Given** the page, **When** the docs check runs, **Then** no link on it is broken.

---

### User Story 3 - A reader who already runs several agents sees how they coordinate and run on their own (Priority: P1)

A developer already has three terminal tabs of Claude Code open, and has had two of them fight over the
simulator. On "Why Agents" they reach one section, "Agents that work together, and on their own". It
opens with one example, told from start to finish. A workflow starts an agent when a pull request's
checks fail. The agent leases the simulator to reproduce the failure, pushes a fix, and waits for the
checks to pass without spending anything while it waits. Once they pass, it publishes
`custom.release_ready`, and a release agent that was waiting for that event wakes up and starts. After the example, the section has one short paragraph each on leases,
events and waiting, workflows, pull requests, and agents managing agents. Each paragraph links to its
docs page.

**Why this priority**: These are what no IDE offers at all. For a reader who already runs several
agents, they are the reason to switch. Without them the pitch would read as a nicer list of agents.

**Independent Test**: A developer who runs several agents reads only this section. They can then say in
their own words how two agents avoid using the simulator at once, and how an agent waits for checks
without anyone checking on it.

**Acceptance Scenarios**:

1. **Given** the page, **When** a reader scans its headings, **Then** leases, events and workflows are
   grouped under one heading, and that heading comes before the servers and spending sections.
2. **Given** that section, **When** read, **Then** it opens with one concrete example that uses at least
   a workflow, a lease and a wait, and every step of the example is something main does today.
3. **Given** each of leases, events and waiting, workflows, pull requests and agents managing agents,
   **When** the reader follows its link, **Then** they reach a docs page that describes it, including
   the list of events an agent can wait for.
4. **Given** the limits of this section (Copilot agents cannot lease, wait or publish; Claude and Cursor
   ask permission before these tools; a scheduled run missed while the app is closed is not run later),
   **When** the section claims these capabilities, **Then** it states the limits or links to where
   they are stated.

---

### User Story 4 - A reader who uses an agent in the terminal or the cloud finds their own comparison (Priority: P2)

A developer runs Claude Code in a terminal, or sends tasks to a cloud agent. They skip the editor
comparison and find a short section for their kind of tool. For a terminal agent, the section says
Agents runs the same tool, and adds the list of agents, the phone, worktrees and workflows around it.
For a cloud agent, the section says the work stays on their Mac or their own servers, with their tools
and their files.

**Why this priority**: These readers are fewer than editor users, but they are more likely to already
run several agents. The editor story is useful without this one.

**Independent Test**: A reader who names their current tool finds the section for its kind in under
thirty seconds, and it names at least two things Agents adds and one thing they keep.

**Acceptance Scenarios**:

1. **Given** the page, **When** a reader scans its headings, **Then** there is one heading for each
   kind of tool: in an editor, in a terminal, in the cloud, and another app that runs several agents.
2. **Given** each such section, **When** read, **Then** it says what the reader keeps, what Agents adds,
   and what the reader would give up.

---

### User Story 5 - The pitch stays true as the app changes (Priority: P3)

Six features later, one of them changes something the pitch claims, for example the phone gains reach
off the local network, or a runtime is added or dropped. The spec for that feature lists "Why Agents"
under its Docs section, and the pitch is changed in the same piece of work.

**Why this priority**: Keeping the pitch true is what makes it trustworthy over time, but it relies on
the process 044 already set up (a Docs section in every spec).

**Independent Test**: Change a claimed behaviour in a test branch without touching the pitch and check
that the review steps flag it. Separately, check that the spec template's guidance names the pitch.

**Acceptance Scenarios**:

1. **Given** the spec template's Docs section, **When** a new spec is written, **Then** its guidance
   says to list "Why Agents" if the feature adds, removes or changes something the pitch claims.

---

### Edge Cases

- **A claim is true on the Mac but not on the phone** (for example, the browser pane or ending a lease).
  The page says which device it is about. The phone section lists only what the phone can do today.
- **A runtime changes what it offers** (for example, Copilot gains the app's tools). The runtime claim
  links to Runtimes, which is where the difference is kept, so the pitch does not state each runtime's
  limits in detail itself.
- **A named example product changes** (for example, an editor adds a phone app). Products are only
  examples of a kind (D2), so a change in one product does not make the page false. Only the section for
  its kind may need a look.
- **A feature merges while the pitch is being written.** Main moved during this spec: 043 (zero-setup
  servers) merged as `075d9f9`. Before publishing, the claims are checked again against main as it is
  then (SC-003), not against this spec.
- **An event is listed but never raised.** `server.offline` and `server.online` are in the app's own
  list of events, so an agent can wait for them. But nothing raises them, because the server connection
  lives in the app and not the daemon, so that agent would wait forever. The docs do not offer them, and
  the pitch does not claim them. The app bug is reported separately and is not fixed here.
- **The reader is on a phone.** The page reads well on a narrow screen: no wide tables that must be
  scrolled sideways to read the main points.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The docs site MUST have a "Why Agents" page that says why a developer who already uses a
  coding agent would use Agents (D1, D4).
- **FR-002**: The page MUST open with a headline and at most three lines that state the case, readable
  without scrolling on a laptop screen.
- **FR-003**: The page MUST say plainly that Agents is not an editor and that the reader keeps the
  editor they use.
- **FR-004**: The page MUST give the reasons in this order:
  1. It runs the agents you already have.
  2. It shows which of many agents needs you, and the work itself: live documents that fill in
     beside the conversation and that you can type on, and changes coloured to the word.
  3. Agents work together and on their own: pull requests watched until they merge, leases, events
     and waiting, workflows, and agents managing agents. Pull request watching comes first in that
     list, because it is the most common reason for agents to work on their own.
  4. Agents keep working without you, and you can follow them from the phone and iPad.

  Servers and spending come after these.
- **FR-004a**: The section on agents working together and on their own MUST open with one concrete
  example, told from start to finish. The example MUST use at least a workflow, a lease and a wait for
  an event, and every step of it MUST be something main does today. The section MUST then give one
  short paragraph, with a link, to each of: leases, events and waiting (including events that agents
  publish themselves), workflows, pull requests, and agents managing agents.
- **FR-005**: The page MUST compare Agents with each kind of tool: an agent in an editor, an agent in a
  terminal, an agent in someone's cloud, and another app that runs several agents. For each kind it MUST
  say what the reader keeps, what Agents adds and what they give up (D2).
- **FR-006**: Other products MAY be named only as examples of a kind. The page MUST NOT make
  feature-by-feature claims about a named product (D2).
- **FR-007**: The page MUST have a "When something else is better" section. It MUST cover at least:
  Mac only, built from source with no download, not an editor, the phone and iPad only on the same
  network, and runtimes differ in what they can do (D3).
- **FR-008**: Every capability the page claims MUST link to the docs page that describes it, and MUST be
  true of main when the page is published.
- **FR-009**: The page MUST NOT mention features that are not on main.
- **FR-010**: The page MUST end with one clearly marked link to the first tutorial.
- **FR-011**: The docs home page and the README MUST each open with a two-line version of the case that
  links to the page. The README's paragraph about each project having a "lead" agent is no longer true,
  and MUST be replaced by it.
- **FR-012**: The page MUST follow the site's existing voice: plain words, short sentences, no
  superlatives or marketing adjectives ("revolutionary", "seamless", "blazing"), no claims about other
  tools' quality.
- **FR-013**: The page MUST pass the docs check (links, placement, front matter, nothing private) and
  read well on a phone-width screen.
- **FR-014**: The spec template's Docs guidance MUST say to list "Why Agents" when a feature adds,
  removes or changes something the page claims.
- **FR-015**: The page MUST NOT describe Agents as open source or state any licence terms while the
  repository carries no licence.
- **FR-016**: Before the pitch claims them, the docs site MUST describe events and waiting as they are on
  main. This means:
  - a reference page listing every event, what raises it and what it carries, including events an agent
    publishes and the old trigger names that are still accepted;
  - a how-to guide on having an agent wait for something;
  - the workflow reference's new dotted triggers and filters;
  - `wait_for_event`, `cancel_wait` and `publish_event` added to the list of tools;
  - the events log on the Mac and on the phone and iPad.
- **FR-018**: The docs site MUST have a how-to guide on following a live document: what opens, how
  changes are marked, typing on it, diagrams as pictures, and doing the same on the phone and iPad. No
  page describes this today; only one line on the phone page and the `show_file` row mention it.
- **FR-017**: Before the pitch claims zero-setup servers, the server docs MUST match 043. Today "Add a
  Linux server" still says to install and sign in to a runtime on the server by hand.

### Key Entities

- **Claim**: one thing the page says Agents does. It has the wording, the docs page it links to, the
  device it applies to, and any limit stated next to it.
- **Kind of tool**: a group the reader's current tool belongs to (in an editor, in a terminal, in the
  cloud, another multi-agent app). Each kind has its example products and its own comparison.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Three developers who use a coding agent, reading the page for two minutes, can each give
  at least three reasons to use Agents and at least one reason not to.
- **SC-002**: A reader finds the comparison for their own kind of tool in under 30 seconds from opening
  the page.
- **SC-003**: 100% of the capability claims on the page link to a docs page, and every one is confirmed
  true on main by one walk before publishing.
- **SC-004**: The page's opening lines fit on the first screen of a 13-inch laptop and of an iPhone
  without scrolling.
- **SC-005**: The whole page takes under five minutes to read (roughly 1,200 words or fewer).
- **SC-006**: The docs check passes with the page in place, with no new warnings.
- **SC-007**: After reading only the coordination section, a developer who runs several agents can
  explain how two agents avoid using the simulator at once, and how an agent waits for checks without
  anyone checking on it.
- **SC-008**: Every event an agent can wait for on main is on the events reference page, with none
  missing when the page is compared against the app's list of events.

## Docs *(mandatory)*

- `docs/explanation/why-agents.md`: add. The pitch itself (D1).
- `docs/explanation/index.md`: change. List the new page first.
- `docs/reference/events.md`: add. Every event, what raises it and what it carries, plus `custom.*`
  events and the old trigger names (FR-016).
- `docs/how-to/wait-for-something.md`: add. Have an agent wait for checks, another agent or the Mac
  waking, and cancel the wait (FR-016).
- `docs/reference/workflows.md`: change. Dotted triggers and filters beside the old names.
- `docs/reference/agent-tools.md`: change. Add `wait_for_event`, `cancel_wait` and `publish_event`.
- `docs/reference/statuses.md`, `docs/explanation/phone-and-ipad.md`: change if needed. Waiting on an
  event, and the events log on the phone and iPad.
- `docs/how-to/add-a-linux-server.md`, `docs/reference/runtimes.md`, `docs/reference/settings.md`:
  change. Claude installed on the server by Agents, and the token in Mac Settings (FR-017).
- `docs/how-to/follow-a-live-document.md`: add. Live documents on the Mac, iPhone and iPad (FR-018).
- `docs/index.md`: change. Open with the two-line case and the link to it (FR-011).
- `mkdocs.yml`: change. Put the page in the nav, first under Explanation.
- `README.md`: change. Two-line case and link at the top in place of the stale "lead" paragraph
  (FR-011).
- `.specify/templates/spec-template.md`: change. The Docs guidance names "Why Agents" (FR-014).

## Assumptions

- The reader already uses at least one coding agent and knows what one is (D4).
- The claims are taken from what main does at `075d9f9` (2026-09-25), including 037 (servers), 038 (pull
  requests), 042 (events and waiting, with the events list on the phone and iPad) and 043 (zero-setup
  servers).
- The only way to get the app is to build it from source, as the first tutorial says. There is no
  download, price or licence to state.
- The site's voice follows the existing docs pages. The pitch is persuasive by being specific, not by
  its adjectives.
- No screenshots are required. Where one helps, such as the list of agents grouped by who needs you,
  it reuses one the docs already have or is taken with the run-app skill on a scratch root.
- Out of scope: a separate marketing site, a landing page with its own design, pricing, comparisons
  with benchmark numbers, and videos.
