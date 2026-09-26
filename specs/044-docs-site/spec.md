# Feature Specification: A Docs Site That Lives With the Code

**Feature Branch**: `044-docs-site`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "I need to build a docs website for the app. I want to use the Diataxis framework and probably GitHub pages. The docs need to stay with the code."

## Why this feature exists

The only documentation for Agents is the README. It was written for whoever builds the app: it covers `xcodebuild` flags,
the daemon's files on disk, `--root`, and scripts to re-ask each runtime what it has. Someone who has just
installed the app gets none of what they need there: how to add a project, start a first agent, answer a
question from the phone, add a server, or what "Blocked" or "Parked" means.

What the person using the app has instead, as of 2026-09-25:

- **No place to start.** No one walks a new user from opening the app to finishing a first agent's turn.
- **No answers to "how do I…".** Adding a Linux server (037), watching a pull request (038), leasing
  a resource (036), using worktrees (030) and starting an agent from the iPhone (029) have all shipped. Each
  one is described only in its own spec, and a spec is written for building the feature, not for using it.
- **No list of what is there.** Four runtimes, the tools an agent is given, the statuses a chat can be in, the
  settings and workflow triggers are not listed anywhere a user would look.
- **No account of why.** Why the agents belong to a daemon and not the window, why an agent's own tools are
  taken away, and why a project lives on one host are explained only in commit messages and specs.
- **Specs describe how the app was, not how it is.** After many features, 035's view of the chat has been
  changed by 039, 040 and 041. The only way to know how the app behaves today is to run it.

This feature gives the app a public docs site in four parts, following the Diataxis framework:
tutorials, how-to guides, reference and explanation. The source lives in this repository beside the code,
changes in the same commit as the behaviour it describes, is checked on every change, and is published when main
moves.

## Clarifications

### Session 2026-09-25

- Q: The repository is private. Where should the docs be readable? → A: On a public site. Anyone can read the docs;
  the code stays private. This needs a GitHub plan that allows Pages from a private repository (FR-012, A-001).
- Q: Who are the docs for? → A: People using the app, on the Mac, iPhone, iPad and servers. Building and
  contributing to the app are out of scope; the README keeps covering that (FR-002, Out of scope).
- Q: How do the docs keep up with the code? → A: A check runs on every change and fails on a broken link or a page
  that is missing or in the wrong place, and every new feature's spec says which docs pages it touches
  (FR-008 to FR-011).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A new user gets from install to a finished agent (Priority: P1)

Someone has heard of Agents and opens the docs site. The home page says what the app is in two sentences
and offers one place to start. They follow the first tutorial, "Your first agent", step by step. It covers
installing the app, adding a folder as a project, choosing a runtime, signing in if asked, writing a prompt,
answering the permission question, and seeing the agent finish. Every step says what they should see on the
screen, and most show a screenshot. At the end they have a finished agent in the "Complete" group and know
where to go next.

**Why this priority**: A docs site that cannot get a new user to their first result has failed at the one thing
only it can do. This story on its own, with a home page and one tutorial, is already a site worth publishing.

**Independent Test**: Give the published site to someone who has not used the app. Without other help they
reach a finished agent by following the tutorial.

**Acceptance Scenarios**:

1. **Given** a person on the home page, **When** they look for where to begin, **Then** one clearly marked link
   takes them to the first tutorial.
2. **Given** the first tutorial, **When** they follow each step on a Mac with at least one supported runtime installed,
   **Then** what they see at each step matches the text and screenshot for that step.
3. **Given** a runtime that is installed but not signed in, **When** they reach that step, **Then** the tutorial
   says what the app shows and what to do, and does not assume they are signed in.
4. **Given** the end of the tutorial, **When** they finish, **Then** the page names the next tutorial and the
   how-to guides they are most likely to need next.

---

### User Story 2 - A user finds how to do one thing (Priority: P2)

Someone already uses the app and wants to do one particular thing, such as add a Linux server, give an agent
its own worktree, reach their agents from the iPhone, have an agent watch a pull request, or set up a workflow
that runs when an agent finishes. They search the site or scan the how-to guides index, find a page named
for that task, and follow it. It assumes they know the basics and lists only the steps for this task.

**Why this priority**: Most visits to docs after the first day are this one. The shipped features no user
can find are the biggest gap today.

**Independent Test**: Pick five tasks from the features shipped so far. For each, a user finds the right page
within two searches or clicks from the home page and completes the task by following it.

**Acceptance Scenarios**:

1. **Given** the how-to guides index, **When** a user scans it, **Then** each guide is named for the task it
   covers, such as "Add a Linux server", not for the feature or spec behind it.
2. **Given** a user who types "server" into the site's search, **When** results appear, **Then** the
   "Add a Linux server" guide is among the first results.
3. **Given** a guide that needs something set up first (a signed-in runtime, the iPhone app paired,
   GitHub access), **When** the user opens it, **Then** it says so at the top and links to where that is covered.
4. **Given** a task that differs between Mac and iPhone/iPad, **When** the user reads the guide, **Then** the
   difference is stated where it applies, not left for them to find.

---

### User Story 3 - A user looks up exactly what something is (Priority: P3)

Someone sees "Parked" on a chat, wonders which runtimes can attach a picture, or wants to know every trigger a
workflow can use. They open the reference section and find a complete list or table covering it, with each
entry described the same way.

**Why this priority**: Reference is what makes the rest trustworthy. Tutorials and guides can link to it
instead of repeating themselves. It matters less than the first two because users reach for it less often.

**Independent Test**: For each reference page, compare its list with the running app (statuses, runtimes,
settings, workflow triggers, agent tools). Nothing the app shows is missing from the page, and nothing on the
page is missing from the app.

**Acceptance Scenarios**:

1. **Given** the reference section, **When** a user opens it, **Then** it contains at least pages for chat
   statuses and groups, runtimes and what each supports, the tools the app gives an agent, settings, workflow
   triggers and actions, and keyboard shortcuts.
2. **Given** a reference page, **When** a user reads any entry, **Then** it has the same parts as every other
   entry on that page (for example, for a status: its name, what it means, what the user can do from it).
3. **Given** a reference page, **When** a user reads it, **Then** it describes and does not instruct. Steps belong
   in a guide, and the reference page links to that guide.

---

### User Story 4 - A user understands why the app works as it does (Priority: P4)

Someone wants to know why their agents keep working after they close the window, why an agent cannot use its
runtime's own scheduler, why only one agent at a time may use the browser, or why a project lives on one
host. They read an explanation page that gives the idea behind it, the trade-off made and what it means for
them, without steps to follow.

**Why this priority**: This changes how people use the app over time but is rarely what they come for first.
It builds on the other three sections.

**Independent Test**: A reader who has read the explanation on agents and the daemon correctly predicts what
happens to a running agent when the window is closed, and when the Mac restarts.

**Acceptance Scenarios**:

1. **Given** the explanation section, **When** a user opens it, **Then** it contains at least pages on the window
   and the daemon, how agents are given and denied tools, projects, hosts and worktrees, leases on shared
   resources, and how the phone and iPad reach the Mac.
2. **Given** an explanation page, **When** a user reads it, **Then** it has no numbered steps and links to the
   guides and reference that go with it.

---

### User Story 5 - A change to the app carries its docs, and a broken page cannot slip through (Priority: P5)

Someone changing the app (an agent or a person) changes what a user sees, such as renaming a status. They
edit the docs page in the same change, in the same repository. If they add a docs page and forget to link it,
link a page that does not exist, or put a page in the wrong section, the change is flagged before it merges.
A new feature's spec lists the docs pages it adds or changes, so docs are planned from the start rather than
remembered at the end.

**Why this priority**: This is what "the docs need to stay with the code" means, and it is what keeps
stories 1–4 true after the next feature. It comes after them because it protects content that must exist
first.

**Independent Test**: Make three deliberately broken changes on a branch: a dead link, an unlinked new page,
and a page outside the four sections. Each is flagged with a message naming the file. Reverting each clears it.

**Acceptance Scenarios**:

1. **Given** a change with a link to a docs page that does not exist, **When** the check runs, **Then** it fails
   and names the file and the link.
2. **Given** a new docs page that no other page or navigation reaches, **When** the check runs, **Then** it
   fails and names the page.
3. **Given** a docs page that does not say which of the four sections it belongs to, **When** the check runs,
   **Then** it fails and names the page.
4. **Given** a new spec started with `/speckit-specify`, **When** it is written, **Then** it has a place to
   list the docs pages the feature adds or changes, or to state that there are none and why.
5. **Given** the docs on a person's own Mac, **When** they want to see the site as it will look, **Then** one
   documented command shows it locally, without publishing.

---

### User Story 6 - Merging to main publishes the site (Priority: P6)

When a change that touches the docs merges to main, the public site shows it a few minutes later. No one
has to run a publish step or remember to. A change that fails the check does not publish.

**Why this priority**: This is needed for the site to exist at all, but it is plumbing, and it is last because
it is worth nothing without pages to publish.

**Independent Test**: Merge a one-word docs change to main. It appears on the public site within 10 minutes.

**Acceptance Scenarios**:

1. **Given** a merged docs change on main, **When** publishing finishes, **Then** the public site shows it.
2. **Given** a change whose check fails, **When** it is on main, **Then** the site keeps the last good version
   and the failure is visible on that commit.
3. **Given** a branch that is not main, **When** it changes the docs, **Then** the public site does not change.

---

### Edge Cases

- **A screenshot goes out of date.** A screenshot showing the old UI is misleading. Each screenshot is stored beside
  the page that uses it, so a change to that page shows its pictures too. Screenshots come from a scratch
  copy of the app and never from a real one, so no private project names, paths or conversations appear
  (FR-013).
- **A feature ships only on the Mac, or only on the phone.** Its pages say which devices it applies to
  (FR-006).
- **A feature is built but not merged.** Docs are written on the feature's branch and appear on the site only
  when it merges (FR-009, User Story 6).
- **A page moves or is renamed.** Old links from outside the site should not silently break. A moved page leaves
  a redirect at its old address (FR-015).
- **Someone lands deep in the site from a search engine.** Every page says which of the four sections it is in
  and links to the start, so a reader who arrives in the middle of a guide is never lost (FR-004).
- **The site fails to publish.** The previous version stays up. A failed publish is visible on the commit
  and never replaces the site with an empty or broken one (User Story 6, scenario 2).
- **A page reads well on a Mac but not on a phone.** Users read the docs on the phone they use to watch their
  agents. The site reads without sideways scrolling on a phone-sized screen, except inside tables and code
  (FR-014).
- **Internal material leaks onto the public site.** Specs, plans, walk notes and memory files stay out of the
  published site. Only the docs source is published (FR-012).

## Requirements *(mandatory)*

### Functional Requirements

**Structure (Diataxis)**

- **FR-001**: The site MUST have four sections: Tutorials, How-to guides, Reference and Explanation. Every page
  MUST belong to exactly one of them.
- **FR-002**: Every page MUST be written for a person using the app. Building, testing or contributing to the app
  is out of scope. The README keeps that.
- **FR-003**: The home page MUST say in a few sentences what the app is, and MUST offer the first tutorial as the one
  place to start, alongside links to the four sections.
- **FR-004**: Every page MUST show which section it is in and MUST provide a way back to that section's index and to
  the home page.
- **FR-005**: Each section MUST follow its Diataxis purpose. A tutorial is a lesson with one path and a visible
  result at the end. A how-to guide covers one task for someone who knows the basics. A reference page describes
  and does not instruct. An explanation page has no steps.
- **FR-006**: Where behaviour differs between the Mac, iPhone, iPad and a server, the page MUST say which applies
  at the point where it differs.

**First content**

- **FR-007**: The first published version MUST include at least:
  - **Tutorials**: "Your first agent" (Mac), and "Follow your agents from your iPhone".
  - **How-to guides**: add a project; start an agent in its own worktree; answer a question or permission request;
    add a Linux server; set up a workflow; have an agent watch a pull request; sign a runtime in; archive, park
    and stop agents; attach files and pictures to a prompt; read an agent's changes.
  - **Reference**: chat statuses and groups; runtimes and what each supports; the tools the app gives agents;
    settings; workflow triggers and actions; keyboard shortcuts.
  - **Explanation**: the window and the daemon; why agents' own tools are taken away; projects, hosts and
    worktrees; leases on shared resources; how the phone and iPad reach the Mac.

**Staying with the code**

- **FR-008**: The docs source MUST live in this repository, under one top-level folder, and be edited as ordinary
  files in the same change as the code they describe.
- **FR-009**: Every change proposed to the repository MUST run a docs check. The check MUST fail, naming the file,
  on: a link to a page or heading within the docs that does not exist; a page that no navigation or other page
  reaches; a page that does not declare its section; a picture a page uses that is missing.
- **FR-010**: The spec template MUST include a "Docs" section in which a feature lists the pages it adds or changes,
  or says there are none and why. `/speckit-specify` MUST fill it in.
- **FR-011**: Anyone with the repository MUST be able to see the site locally, as it will be published, with one
  documented command and without publishing.

**Publishing**

- **FR-012**: The site MUST be published publicly from main, automatically, after the check passes. Only the docs
  folder's content MUST be published. Specs, plans, source code and anything else in the repository MUST NOT be.
- **FR-013**: Screenshots and examples MUST come from a scratch copy of the app. They MUST NOT show real project
  names, file paths, conversations, server addresses or tokens.
- **FR-014**: The site MUST be readable on phone, tablet and desktop screens, MUST follow the reader's light or dark
  preference, and MUST work without the reader signing in.
- **FR-015**: The site MUST offer search across all pages. A page that moves MUST leave a redirect at its old address.
- **FR-016**: A failed check or publish MUST leave the previously published site in place.

### Key Entities

- **Page**: One document on the site. It has a title, exactly one section, the devices it applies to where that
  matters, and links to related pages in other sections.
- **Section**: One of the four Diataxis sections. It has an index page listing its pages in a deliberate order.
- **Screenshot**: A picture used by one page. It is stored beside that page and taken from a scratch copy of the app.
- **Docs note in a spec**: The list, in a feature's spec, of the pages that feature adds or changes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Someone who has never used the app gets from the home page to a finished agent within 15 minutes, by
  following the first tutorial alone.
- **SC-002**: For five tasks chosen from shipped features, a user finds the right guide within two searches or
  clicks from the home page, five times out of five.
- **SC-003**: Every reference list matches the running app when first published: no status, runtime, setting,
  workflow trigger or agent tool is missing from or extra to its page.
- **SC-004**: Each of the three deliberately broken changes in User Story 5 (dead link, unreached page, page with no
  section) fails the check every time and names the file.
- **SC-005**: A docs change merged to main is visible on the public site within 10 minutes, with no manual step.
- **SC-006**: No published page or picture shows a real project name, home-directory path, conversation, server
  address or token, checked page by page before first publishing.
- **SC-007**: Every page reads on a phone-sized screen without sideways scrolling of body text.

## Docs

This feature creates the docs site. It adds all the pages listed in FR-007, and adds the "Docs" section to the spec
template (FR-010).

## Assumptions

- **A-001**: ~~Alex's account publishes Pages from a private repository.~~ It does not: the plan refused Pages
  for a private repository (2026-09-25). Alex chose to make `alexec/Agents` public instead, after a history scan
  found no real secrets, and Pages was turned on with GitHub Actions as its source the same day.
- **A-002**: The site is published on GitHub Pages at its default address. A custom domain can be added later
  without changing any page.
- **A-003**: The tool that turns the docs source into a site is chosen in `/speckit-plan`. It must work from
  plain-text files in the repository and must not need a server of its own.
- **A-004**: The docs are written in English, with the plain, direct tone of the app's own text.
- **A-005**: Reference pages are written by hand in this version and checked against the running app when they
  are written (SC-003). Generating them from the source is a possible follow-up, not part of this feature.
- **A-006**: The README stays as the entry point for building and working on the app, and links to the docs site
  for using it.
- **A-007**: Screenshots are taken with the existing `run-app` skill on a scratch root, and phone and iPad pictures
  come from Alex's devices, since this Mac cannot drive a simulator.

## Out of scope

- Docs for building, testing or contributing to the app.
- Versioned docs (one site per release). The site describes main.
- Translations.
- Reference generated from source code.
- Docs shown inside the app itself.
