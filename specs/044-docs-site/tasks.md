# Tasks: A Docs Site That Lives With the Code

**Input**: Design documents from `specs/044-docs-site/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: The spec asks for proof that each kind of break is caught (User Story 5, SC-004), so the check gets a
self-test (T041). Content is checked by `scripts/docs.sh check` after every page task, and by reading it against
the running scratch app.

**Working rules for every task**:
- Work only in `.agents/worktrees/044-docs-site`.
- Run `scripts/docs.sh check` after each page, once T006 exists.
- Screenshots come from the `run-app` skill on scratch root `/tmp/run-044`:
  - take the `screen` lease before and release it right after;
  - drive the window only when Alex is away, and otherwise screenshot by window id;
  - never capture the real app.
- Page shapes are in `contracts/page-front-matter.md`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1–US6 from spec.md

---

## Phase 1: Setup

**Purpose**: An empty site that builds and serves.

- [X] T001 Add `site/` and `.cache/` to `.gitignore`.
- [X] T002 Create `mkdocs.yml` at the repository root:
  - `site_name: Agents`, `site_url: https://alexec.github.io/Agents/`, `docs_dir: docs`,
    `repo_url: https://github.com/alexec/Agents`, `strict: true`;
  - `theme`: `name: material`, `features: [navigation.tabs, navigation.sections, navigation.indexes,
    navigation.top, search.suggest, search.highlight, content.code.copy]`;
  - `palette` following the system preference, with a light and a dark scheme and a toggle;
  - `plugins: [search, redirects: {redirect_maps: {}}]`;
  - `markdown_extensions: [admonition, attr_list, md_in_html, tables, toc: {permalink: true},
    pymdownx.details, pymdownx.superfences, pymdownx.tabbed: {alternate_style: true}]`;
  - a `nav:` with Home plus the four sections, each an index page only (research R1, R2).
- [X] T003 Create `scripts/docs.sh` (executable, POSIX sh) per `contracts/docs-check-cli.md`:
  - it resolves the repository root from its own path;
  - it pins `ZENSICAL=zensical==0.0.65` in one variable;
  - `serve` runs `uvx "$ZENSICAL" serve -a 127.0.0.1:8000`, `build` runs `uvx "$ZENSICAL" build --strict --clean`,
    and `check` runs `python3 scripts/docs-check.py` and then `build`;
  - any other argument prints usage and exits 2.
- [X] T004 [P] Create the skeleton pages with front matter `diataxis: index`: `docs/index.md` (placeholder) and
  `docs/tutorials/index.md`, `docs/how-to/index.md`, `docs/reference/index.md`, `docs/explanation/index.md`. Each
  section index gets one sentence on what the section is for, in Diataxis terms, with a page list to fill in.
- [X] T005 [P] Copy the app's logo from `design/logo/` into `docs/assets/` as `logo.svg`/`logo.png` and a favicon,
  and set `theme.logo` and `theme.favicon` in `mkdocs.yml`.

**Checkpoint**: `scripts/docs.sh build` exits 0, and `scripts/docs.sh serve` shows five pages with four tabs.

---

## Phase 2: Foundational

**Purpose**: The check that every page is written against, and a scratch app to take screenshots from. Both are
needed before any content.

- [X] T006 Write `scripts/docs-check.py` (Python 3.9+, standard library only) per `contracts/docs-check-cli.md`.
  - **Inputs**: it reads `docs_dir` and `nav` from `mkdocs.yml` with a small indentation parser (no PyYAML), and
    walks `docs/**/*.md` and `docs/**/images/*`.
  - **Rules** (codes from the contract), each reported as `path:line: message`:
    - section-missing, section-unknown, section-folder: `diataxis` is one of `tutorial`, `how-to`, `reference`,
      `explanation`, `index`; `index` only for `docs/index.md` and `docs/<section>/index.md`; the folder maps
      `tutorial→tutorials/`, `how-to→how-to/`, `reference→reference/` and `explanation→explanation/`.
    - nav-missing, nav-dead, nav-twice.
    - image-missing, image-unused, image-alt, and image-large (> 400 KB).
    - private: `/Users/`, `/private/`, `/tmp/run-`, `alexcollins`, any IPv4 address other than `127.0.0.1`,
      `ghp_`, `github_pat_`, `sk-ant-`, `xox[abp]-`.
    - shape-steps: an explanation page has an ordered list, outside code blocks.
    - shape-where-next: a tutorial has no `## Where next`.
  - It ignores fenced code blocks for everything except the private check.
  - **Output**: the summary line `docs-check: ok (M pages, K pictures)` or `docs-check: N problems in M pages`.
  - **Exit**: 0, 1 if there are problems, 2 if it cannot run. `--root` is optional.
- [X] T007 Run `scripts/docs.sh check` on the skeleton, and fix the pages or the script until it prints `ok`.
- [X] T008 Set up the demo projects for screenshots, `scripts/docs-demo.sh`:
  - it creates `/tmp/run-044/demo/weather-app` (a small git repo: README, a Swift file, one failing test) and
    `/tmp/run-044/demo/recipes-site` (HTML/CSS);
  - it launches the branch build on root `/tmp/run-044` through the `run-app` skill's launch step with a clean
    environment;
  - it adds both folders as projects over `daemon.sock`;
  - it never touches `~/Library/Application Support/Agents`.

  Document how to run it in a comment at the top.

**Checkpoint**: the check passes on the skeleton, and a scratch window shows the two demo projects and nothing
of Alex's.

---

## Phase 3: User Story 1 — A new user gets from install to a finished agent (P1) 🎯 MVP

**Goal**: A home page with one "Start here", and a tutorial that ends with a finished agent.

**Independent Test**: quickstart V3 and V4. Following *Your first agent* on the scratch app matches every "You
should see", and ends in Complete.

- [X] T009 [US1] Write `docs/index.md`:
  - two sentences on what Agents is, taken from the README's opening but written for a user;
  - one prominent "Start here → Your first agent" link;
  - four cards or links to the sections, each with one line;
  - a line on the devices (Mac app; iPhone and iPad follow the Mac; Linux servers).
- [X] T010 [US1] Walk the first run on the scratch app, taking notes of every screen and wording, before writing.
  The walk covers: install and open → add `weather-app` → start an agent with Claude → the sign-in state if not
  signed in → prompt "Why does the test fail? Fix it." → the permission question → Complete.
- [X] T011 [US1] Write `docs/tutorials/first-agent.md` (`diataxis: tutorial`, `devices: [mac]`):
  - "What you'll have at the end" with a picture, then "Before you start" (a Mac, one runtime installed; link to
    `reference/runtimes.md`).
  - Numbered steps from T010, each ending "You should see…", and a step for "if the runtime is not signed in"
    that does not assume sign-in.
  - "Where next", linking to the iPhone tutorial and the three most likely guides.
- [X] T012 [US1] Take the screenshots for T011 as `docs/tutorials/images/first-agent-01.png …`: window only,
  cropped to the step, ≤ 400 KB, with alt text on every use.
- [X] T013 [US1] Write `docs/tutorials/follow-from-iphone.md` (`diataxis: tutorial`, `devices: [mac, iphone]`):
  - pair the phone with the Mac;
  - see the agent from T011 in the list;
  - answer a question from the phone;
  - start a new agent from the phone;
  - "Where next".

  Take the wording from specs 029, 033 and 034 and the Remote app's source, and leave picture placeholders named
  `follow-from-iphone-NN.png`, listed at the end of the task notes.
- [X] T014 [US1] Ask Alex (AskUserQuestion) for the iPhone screenshots for T013 against the scratch root, with the
  list of shots. Save them in `docs/tutorials/images/`. Until then, the page uses Mac pictures where they apply
  and states which steps have no picture yet.
- [X] T015 [US1] Fill in `docs/tutorials/index.md` and the Tutorials section of `nav:` in `mkdocs.yml`, then run
  `scripts/docs.sh check`.
- [X] T016 [US1] **Look gate**: run `scripts/docs.sh serve`, screenshot the home page and the tutorial at desktop
  and phone widths, and ask Alex (AskUserQuestion, screenshots attached through `show_file`) whether the layout,
  tone and depth are right before writing more pages. Apply the answer to the page template in
  `contracts/page-front-matter.md` if anything changes.

**Checkpoint**: US1 is a publishable site on its own.

---

## Phase 4: User Story 2 — A user finds how to do one thing (P2)

**Goal**: Ten task-named guides, each short, assuming the basics, with device differences inline.

**Independent Test**: quickstart V3's search check. For five tasks, the right guide is found within two searches or
clicks.

For each guide: read the named specs and the app's current source for exact labels, check them on the scratch app,
write the guide in the how-to shape, add pictures only where a step is hard to find, and add it to `nav:`.

- [X] T017 [P] [US2] `docs/how-to/add-a-project.md`: add a folder, clone a repository, remove or archive a
  project, the lead agent (specs 025, 026).
- [X] T018 [P] [US2] `docs/how-to/start-in-a-worktree.md`: choose a worktree when starting, what happens on
  archive, on iPhone/iPad (specs 030, `0ea158d`).
- [X] T019 [P] [US2] `docs/how-to/answer-a-question.md`: permission requests, questions, multi-question forms,
  from the Mac, the phone and notifications; covers Grok's needs-answer case (specs 023, 039, some-ux-issues-1).
- [X] T020 [P] [US2] `docs/how-to/add-a-linux-server.md` (`devices: [mac, server]`):
  - what a server needs;
  - Add a server;
  - a server project;
  - offline and update;
  - removing a server (spec 037, `specs/037-cloud-agents/walk/README.md`).

  Its example host is `devbox.example.com`, never a real address.
- [X] T021 [P] [US2] `docs/how-to/set-up-a-workflow.md`: the workflows page, triggers, actions, one worked
  example "when an agent finishes, start a reviewer" (spec 017, the workflow page source).
- [X] T022 [P] [US2] `docs/how-to/watch-a-pull-request.md`: start an agent on a PR and let it babysit, with the
  GitHub access it needs (spec 038). Examples use `example/repo`.
- [X] T023 [P] [US2] `docs/how-to/sign-a-runtime-in.md`: sign in from the app, and the runtimes that hand over a
  terminal command (README "Signing in").
- [X] T024 [P] [US2] `docs/how-to/archive-park-stop.md`: stop, park, archive and unarchive, what each keeps, and
  swipe to archive (specs 040, some-ux-issues-1).
- [X] T025 [P] [US2] `docs/how-to/attach-files.md`: drag, paste, `@` mention, and what each runtime accepts;
  links to reference/runtimes.
- [X] T026 [P] [US2] `docs/how-to/read-an-agents-changes.md`: the Changes pane, diffs in the chat, Whole file,
  the files pane, `show_file` (specs 035, 041).
- [X] T027 [US2] Fill in `docs/how-to/index.md`, grouped by area (Projects, Agents, Servers, Phone and iPad,
  Automation), and the How-to section of `nav:`. Run `scripts/docs.sh check`, and check the search for "server",
  "worktree" and "pull request" in `serve`.

**Checkpoint**: US1 and US2 both pass their tests.

---

## Phase 5: User Story 3 — A user looks up exactly what something is (P3)

**Goal**: Complete, uniform lists that match the app.

**Independent Test**: quickstart V5. Each list compared with its source of truth has nothing missing and nothing extra.

- [X] T028 [P] [US3] `docs/reference/statuses.md`: one table (Status | Group | What it means | What you can do)
  from `AgentGroup` and the status enum in `Packages/AgentsKit`. It covers Needs attention, Blocked, Working,
  Complete, Stopped, Parked and Archived.
- [X] T029 [P] [US3] `docs/reference/runtimes.md`: one table (Runtime | Command it starts | Pictures |
  Sign in from app | App tools available | Notes) from `ToolPolicyCatalog`, the runtime catalogue and the README.
  It covers Claude, Grok, Copilot and Cursor, including that Copilot sessions get none of the app's tools.
- [X] T030 [P] [US3] `docs/reference/agent-tools.md`: one entry per tool on the app's MCP server (Tool | What it
  does | Who it asks), taken from the helper's tool list in source, not from memory (research R9).
- [X] T031 [P] [US3] `docs/reference/settings.md`: every Settings pane and control on the Mac (including Servers,
  Theme) and on iPhone/iPad, from the Settings views' source.
- [X] T032 [P] [US3] `docs/reference/workflows.md`: triggers, conditions and actions, with the file format, from
  `Packages/AgentsKit/Sources/AgentsKit/Workflows/`.
- [X] T033 [P] [US3] `docs/reference/keyboard-shortcuts.md`: every `.keyboardShortcut` and menu command in `App/`,
  from a grep of the source.
- [X] T034 [US3] Fill in `docs/reference/index.md` and `nav:`. For each page, record in its task line the file(s)
  it was checked against, and run `scripts/docs.sh check`.

**Checkpoint**: US1–US3 pass their tests.

---

## Phase 6: User Story 4 — A user understands why the app works as it does (P4)

**Goal**: Short explanations with no steps, each linking to its guides and reference.

**Independent Test**: the spec's test. After reading *The window and the daemon*, a reader predicts what happens to
a running agent when the window closes and when the Mac restarts.

- [X] T035 [P] [US4] `docs/explanation/window-and-daemon.md`: the daemon owns the agents, the window is a view,
  the daemon exits when idle, and what survives a restart (README "The daemon").
- [X] T036 [P] [US4] `docs/explanation/scoped-tools.md`: why a runtime's own scheduler, question and subagent
  tools are taken away, and what is kept (README "Scoping an agent's tools").
- [X] T037 [P] [US4] `docs/explanation/projects-hosts-worktrees.md`: a project is a folder on one host, and why
  worktrees (specs 030, 037).
- [X] T038 [P] [US4] `docs/explanation/leases.md`: why one agent at a time uses the screen or a browser, waiting in
  line, and what a person can end (spec 036).
- [X] T039 [P] [US4] `docs/explanation/phone-and-ipad.md`: how the phone and iPad reach the Mac and what they can
  and cannot do (specs 013, 029, 033, 034). It does not describe network internals beyond what a user needs.
- [X] T040 [US4] Fill in `docs/explanation/index.md` and `nav:`, and run `scripts/docs.sh check`.

**Checkpoint**: all four sections are complete.

---

## Phase 7: User Story 5 — A change to the app carries its docs (P5)

**Goal**: Breaks are caught before merge, and new specs plan their docs.

**Independent Test**: quickstart V2, plus a pull request with a deliberate break failing `docs-check`.

- [X] T041 [US5] Write `scripts/docs-check-selftest.sh`. It copies the repository's `mkdocs.yml` and `docs/` into
  `mktemp -d`, and for each break, applied to the copy only, runs `docs-check.py --root <copy>` and the strict
  build. It asserts a non-zero exit and that the output names the broken file. The breaks are:
  - a dead link;
  - a dead anchor;
  - a page not in the nav;
  - a page with no `diataxis`;
  - a tutorial page in `how-to/`;
  - a missing picture;
  - a `/Users/someone` path.

  It prints `PASS <break>` or `FAIL <break>` for each, exits non-zero on any FAIL, and deletes the copy on exit.
  It never writes under the real `docs/`.
- [X] T042 [US5] Run `scripts/docs-check-selftest.sh`. All must PASS, and `git status docs/` must be clean
  afterwards.
- [X] T043 [P] [US5] Create `.github/workflows/docs-check.yml`:
  - `on: pull_request` and `push` (all branches);
  - `permissions: contents: read`;
  - one job on `ubuntu-latest` with checkout, `astral-sh/setup-uv@v6`, `scripts/docs.sh check` and
    `scripts/docs-check-selftest.sh`;
  - a 10-minute timeout.
- [X] T044 [P] [US5] Add the `## Docs *(mandatory)*` section to `.specify/templates/spec-template.md` after
  Success Criteria, exactly as in `contracts/spec-docs-section.md`.
- [X] T045 [P] [US5] Add to `README.md`, near the top, one line: "Using the app? The docs are at
  https://alexec.github.io/Agents/ (source in `docs/`; preview with `scripts/docs.sh serve`)". Add a sentence to
  "How work happens here" saying each spec's Docs section lists its pages.
- [X] T046 [US5] Document redirects in a comment above `redirect_maps` in `mkdocs.yml`: "a moved page leaves
  `old.md: new.md` here".

**Checkpoint**: the check is proven, and CI will run it once pushed.

---

## Phase 8: User Story 6 — Merging to main publishes the site (P6)

**Goal**: main publishes by itself, and a failure keeps the last good site.

**Independent Test**: quickstart V7.

- [X] T047 [US6] Create `.github/workflows/docs-publish.yml`:
  - **Trigger**: `on: push: branches: [main], paths: [docs/**, mkdocs.yml, scripts/docs*, .github/workflows/docs-publish.yml]`,
    plus `workflow_dispatch`.
  - **Concurrency**: `group: pages`, `cancel-in-progress: false`.
  - **Build job**: permissions `contents: read`; runs checkout, setup-uv, `scripts/docs.sh check`,
    `actions/configure-pages@v5` and `actions/upload-pages-artifact@v3` with `path: site`.
  - **Deploy job**: `needs: build`; `environment: github-pages` with the URL taken from the deploy step;
    permissions `pages: write` and `id-token: write`; runs `actions/deploy-pages@v4`.
- [X] T048 [US6] Ask Alex (AskUserQuestion) to confirm that the account has GitHub Pro or above, and whether to turn
  on Pages with `gh api -X POST repos/alexec/Agents/pages -f build_type=workflow` or through Settings himself.
  Do not run it unasked (research R4).
- [X] T049 [US6] After the branch merges (when Alex says it is this lane's turn), watch the first `docs-publish` run
  with `gh run watch`, open `https://alexec.github.io/Agents/`, and record the time from merge to live (SC-005)
  in `specs/044-docs-site/walk/README.md`.

---

## Phase 9: Polish and Cross-Cutting

- [X] T050 Privacy pass (quickstart V6): open every picture under `docs/**/images/` and read every page once.
  Replace anything showing a real project, path, conversation, address or token, and note in
  `specs/044-docs-site/walk/README.md` that this was done, with the date.
- [X] T051 Phone-width pass (SC-007): in `serve`, take screenshots at 390 px wide of the home page, one page of each
  section and the widest table, and fix any sideways scroll of body text.
- [X] T052 Run the full quickstart (V1–V6), and record the results and any gaps in
  `specs/044-docs-site/walk/README.md`.
- [X] T053 Hand quickstart V4's timed run by a new user (SC-001) and the iPhone reading (V7.4) to Alex as the two
  things only he can do, listed in the walk README.
- [X] T054 Stop the scratch app and its daemon on `/tmp/run-044` by the pid in its `daemon.lock` (never pattern-kill
  `agentsd`), and delete `/tmp/run-044`.

---

## Dependencies and Execution Order

- **Setup (T001–T005)** → **Foundational (T006–T008)** → the stories.
- **US1 (T009–T016)** comes first and ends in a look gate (T016). The other content stories wait on that answer,
  so that 20 pages are not written to a template Alex would change.
- **US2, US3 and US4** are independent of each other after T016. Within each, the page tasks are [P], and the
  index/nav task comes last.
- **US5**:
  - T041–T042 need only T006.
  - T043–T046 can start any time after T006.
  - The Docs section in the template (T044) is independent of the site.
- **US6**:
  - T047 needs T003 and T006.
  - T048 is Alex's decision and can be asked early.
  - T049 needs the merge.
- **Polish** comes after all content.

### Parallel examples

- US2: T017–T026 are ten files with no shared state; up to three agents can each take a group (projects/agents,
  servers/automation, files/sign-in). Each appends only its own `nav:` lines in T027, done by one of them at the end.
- US3: T028–T033 can run in parallel; T034 closes the phase.
- US4: T035–T039 can run in parallel; T040 closes the phase.
- US5's T043, T044 and T045 can run in parallel with any content phase.

## Implementation Strategy

1. **MVP**: Setup, Foundational and US1 give a home page, one real tutorial, and a check. Stop at the look gate
   (T016) and show Alex.
2. Then US5 (T041–T046), so every later page is written under the check CI will run.
3. Then content: US2, then US3, then US4, which can overlap.
4. Then US6 once Pages is on, and merge when it's this lane's turn.
5. Polish, and hand the two human-only checks to Alex.
