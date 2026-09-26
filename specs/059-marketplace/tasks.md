# Tasks: Search a Catalogue and Add Skills to You or a Project

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/catalog-methods.md](contracts/catalog-methods.md),
[contracts/lock-files.md](contracts/lock-files.md), [quickstart.md](quickstart.md),
[look/](look/README.md) (approved by Alex, 2026-09-26, as drawn)

**Tests**: Included. This repo tests every daemon behaviour, and the quickstart names each
property. Write each test before the code that makes it pass.

- Network tests use a `URLProtocol` stub, following
  `Tests/Unit/CredentialCheckTests.swift`.
- `gh` is `Tests/Support/FakeGitHub.swift`.
- Every test uses a temporary root and a temporary personal home passed in directly. None reads
  `$HOME` or reaches the network.

**Where**: Everything runs in the worktree `.agents/worktrees/059-marketplace` on branch
`agents/059-marketplace`. Never edit the shared checkout. Paths use these short forms:

| Short form | Means |
|---|---|
| `Pkg/` | `Packages/AgentsKit/` |
| `Src/` | `Pkg/Sources/AgentsKit/` |
| `Core/` | `Pkg/Sources/AgentsKitCore/` |
| `Tests/` | `Pkg/Tests/AgentsKitTests/` |
| `App/` | `App/Sources/` |

New App files are picked up by `project.yml` (XcodeGen), so run `xcodegen generate` after adding
any.

**Rules this feature must keep**:
- **Never touch an unmanaged skill.** A folder with no lock entry is never written, moved or
  removed (FR-013, SC-004).
- **Full or nothing.** A destination ends up exactly as before or exactly as previewed (FR-009,
  SC-003).
- **The CLI's lock files stay the CLI's.** Write its shape byte for byte. Add no key of the
  app's own. Keep every key the app doesn't own. Refuse to write a file that is unreadable or on
  an older version (contracts/lock-files.md).
- **Never the real home.** A scratch root or a test never reaches the real home or the real
  Trash. A scratch root's Trash is `<root>/trash/` (FR-024, R9).
- **Only the query and the repository leave the Mac.** No file contents, tokens or `gh` output
  are logged (FR-023).
- **Control-only.** `catalog/*` and `skills/*` are never added to `deviceMethods` or
  `agentMethods`.
- **The views match** the approved frames A–E. The one exception: the commit date shows only
  when `gh` is signed in (R4).

**Order**:
1. Hashes and locks, checked against golden values.
2. Sources.
3. US1, the MVP: preview → add to You → the sheet and Shared.
4. US2: projects.
5. US3: update and remove.
6. US4: clashes and failures.
7. Polish: interop and docs.

---

## Phase 1: Setup

- [X] T001 Create the folders `Src/Catalog/`, `Tests/Catalog/`, `Tests/Catalog/Fixtures/`, `App/Catalog/` and `specs/059-marketplace/walk/`; run `xcodegen generate` and confirm the app scheme still builds (`xcodebuild -scheme Agents -skipPackagePluginValidation build`)
- [X] T002 [P] Make three fixture skill folders under `Tests/Catalog/Fixtures/skills/`:
  - `plain/`: SKILL.md plus `notes.md`;
  - `mixed/`: SKILL.md, `README.md`, `a_b.md`, `a-b.md`, `Zeta.md`, `alpha.md`;
  - `nested/`: SKILL.md, `scripts/lint.sh` (mode 755, `#!/bin/sh`), `assets/logo.png` (binary), `references/x.md`.
- [X] T003 [P] Write `specs/059-marketplace/walk/golden.mjs`. It copies `computeSkillFolderHash` from the `skills` CLI 1.7.0 verbatim and prints each fixture's hash. Record the output in `Tests/Catalog/Fixtures/golden.json` as `computedHash`.
- [X] T004 [P] Add each fixture to a temporary git repo, run `git write-tree`, and record the output of `git rev-parse <tree>:<folder>`, plus every file's `git hash-object`, in `Tests/Catalog/Fixtures/golden.json` as `treeSHA` and `blobs`. Add the real skill measured in research R3: `avdlee/swiftui-agent-skill`, folder `skills/swiftui-expert-skill`, tree `4b58ee6b6270e512f22054e0eb7e0d719b43128d`.
- [X] T005 [P] Record trimmed real responses as fixtures in `Tests/Catalog/Fixtures/http/`:
  - skills.sh search (`search-swiftui.json`);
  - download (`download-swiftui-expert-skill.json`, trimmed to 3 files);
  - the git ref list (`info-refs.txt`);
  - a tree (`tree.json`);
  - an api.github.com 403 with `x-ratelimit-remaining: 0` (`rate-limited.json`).
- [X] T006 Write the `URLProtocol` stub in `Tests/Support/CatalogStub.swift`. It answers per host and path from `Tests/Catalog/Fixtures/http/`, records every request, and can be switched to "down" (503) or "rate-limited".

---

## Phase 2: Foundational (blocks every story)

**Purpose**: hashes, the lock files, the sidecar, destinations, the wire types and the two sources. Every story uses all of them.

### Tests first

- [X] T007 [P] Write `Tests/Catalog/SkillHashesTests.swift`:
  - `computedHash` of each fixture equals `golden.json`;
  - `treeSHA` equals `golden.json`;
  - `blobSHA` of every fixture file equals `golden.json`;
  - the two orders differ on `mixed/` (git order versus `localeCompare` order), so a wrong comparator fails the test.
- [X] T008 [P] Write `Tests/Catalog/SkillLocksTests.swift`, covering:
  - a personal lock with `dismissed`, `lastSelectedAgents` and an unknown top-level key, and three skills, round-trips byte-identical except for the one entry written;
  - `installedAt` is kept on replace and `updatedAt` is set to now, in ISO 8601 with milliseconds and `Z`;
  - the file is written with two-space indentation and **no trailing newline** (personal);
  - the project lock has sorted keys, 2-space indentation, a **trailing newline**, and only `version` and `skills`;
  - `version` 2 or unparseable JSON throws `lockUnreadable` and the file is unchanged;
  - `XDG_STATE_HOME` moves the personal path to `$XDG_STATE_HOME/skills/.skill-lock.json`.
- [X] T009 [P] Write `Tests/Catalog/CatalogSidecarTests.swift`: the key is `"<destinationKey>/<name>"`; an entry whose lock entry is gone is dropped at the next write; a missing file reads as empty.
- [X] T010 [P] Write `Tests/Catalog/DestinationTests.swift`:
  - `personal` resolves to `<personalHome>/.agents/skills` and to **nil** when `StoreLocations.personalHome` is nil;
  - `project` resolves to `<folder>/.agents/skills` for a known project or a worktree of one;
  - `project` is refused for an unknown folder or a server project (R10);
  - the Trash is `<root>/trash/` whenever the root is not the standard root or `AGENTS_PERSONAL_HOME` is set (R9).
- [X] T011 [P] Write `Tests/Catalog/GitHubSourceTests.swift` against `CatalogStub` and `FakeGitHub`:
  - HEAD and the default branch are parsed from `info-refs.txt`;
  - the tree goes through `gh api` when `FakeGitHub` is signed in, and anonymously when it is not;
  - raw is fetched at the commit, never at the branch;
  - rate-limited goes to the tarball fallback, which extracts only the skill folder and is refused over 50 MB;
  - `AGENTS_TEST_GITHUB_URL` sends all three hosts to the stub.
- [X] T012 [P] Write `Tests/Catalog/SkillsCatalogTests.swift`:
  - results come back in skills.sh's order;
  - non-GitHub `source` rows are dropped (R1);
  - a query shorter than 2 characters makes no request;
  - `known` is true only for owners in `KnownOwners`, compared case-insensitively (R11);
  - down gives `unreachable("skills.sh")`, never an empty list;
  - `AGENTS_TEST_CATALOG_URL` is honoured.
- [ ] T013 (open: the daemon-level role test was stopped by a safety check, 2026-09-26; Alex chose to skip it for now) [P] Write `Tests/Catalog/CatalogRolesTests.swift`: every `catalog/*` and `skills/*` method is refused for `.device`, `.agent`, `.pairing` and `.stranger`, and allowed for `.control` (quickstart §3 step 14).

### Implementation

- [X] T014 [P] Write `Src/Catalog/SkillHashes.swift`:
  - `blobSHA(Data)`: SHA-1 of `"blob <len>\0" + data`;
  - `treeSHA(folder:)`: git tree objects with mode `100644`, `100755` and `40000`, sorted by git's rule (a folder's name is compared as if it ended in `/`), with symbolic links refused;
  - `computedHash(folder:)`: SHA-256 over each file's relative path (UTF-8, `/` separators) then its bytes, in the `localeCompare`-equivalent order T007 pins down, skipping `.git` and `node_modules`.

  Use CryptoKit on macOS and swift-crypto only if it is already a dependency, otherwise CommonCrypto behind `#if canImport`. Make T007 pass.
- [X] T015 [P] Write `Src/Catalog/SkillLocks.swift`:
  - `PersonalLock` (version 3) and `ProjectLock` (version 1) are read as `JSONValue`, so unknown keys survive;
  - `upsert(name:entry:)` and `remove(name:)`;
  - entries are exactly the fields in contracts/lock-files.md;
  - writes are atomic (temp file then rename).

  Make T008 pass.
- [X] T016 [P] Write `Src/Catalog/CatalogSidecar.swift` for `<root>/catalog-skills.json` (contracts/lock-files.md). Make T009 pass.
- [X] T017 [P] Write `Src/Catalog/KnownOwners.swift` with the R11 list verbatim: `anthropics, openai, google, google-gemini, github, microsoft, vercel, vercel-labs, apple, expo, figma, stripe, supabase, cloudflare`.
- [X] T018 Write the wire types in `Core/Daemon/DaemonAPI+Catalog.swift`, exactly as in contracts/catalog-methods.md and data-model.md:
  - the method names `catalog/search`, `catalog/preview`, `catalog/destination-state`, `skills/add`, `skills/list`, `skills/check-updates`, `skills/update-preview` and `skills/remove`;
  - the types `Destination`, `CatalogResult`, `SkillPreview`, `PreviewFile`, `PreviewProblem`, `DestinationState`, `ManagedSkill`, `UpdateState`, `ListedSkill` and `CatalogError` (`unreachable(host)`, `rateLimited(retryAfter)`, `unmanaged(path)`, `lockUnreadable(path)`, `noPersonalHome`, `previewExpired`).

  `SharedSnapshot.Skill` gains `managed: ManagedSkill?`, decoded when present so older snapshots still decode.
- [X] T019 Write `Src/Catalog/Destination.swift`, which resolves a `Destination` to its skills folder, its lock file and its Trash from `StoreLocations` and the project records. Make T010 pass.
- [X] T020 [P] Write `Src/Catalog/GitHubSource.swift`:
  - `head(owner:repo:)` via the smart-HTTP ref list;
  - `tree(owner:repo:commit:)` via `GitHubCLI` `api` when signed in, else anonymous `URLSession`;
  - `raw(owner:repo:commit:path:)`;
  - `commitDate(owner:repo:commit:folder:)`, only when `gh` is signed in (R4);
  - `tarballFolder(owner:repo:commit:folder:into:)` via codeload and `/usr/bin/tar`, capped at 50 MB.

  Every request has a 10 s timeout and a test-overridable base (`AGENTS_TEST_GITHUB_URL`). Make T011 pass.
- [X] T021 [P] Write `Src/Catalog/SkillsCatalog.swift`: `search(query:)` and `snapshot(owner:repo:skillID:)` against `AGENTS_TEST_CATALOG_URL` or `https://skills.sh`. Make T012 pass.
- [X] T022 Add the new methods to the dispatch table in `Src/Daemon/DaemonCore+Dispatch.swift` as `notImplemented` stubs, not in `deviceMethods` or `agentMethods`. Make T013 pass.

**Checkpoint**: `swift test --filter Catalog` is green and the golden values match. Commit.

---

## Phase 3: User Story 1 — Find a skill and add it for every agent you start (P1) 🎯 MVP

**Goal**: frames B and C, and frame A's Add skill…, working end to end for the personal destination.

**Independent test**: quickstart §3 steps 1–5 on a scratch root, then frames A–C on screen.

### Tests first

- [X] T023 [P] [US1] Write `Tests/Catalog/SkillPreviewerTests.swift`:
  - the folder is found by folder name, then by the front-matter `name` put through `toSkillSlug`; `notFoundInRepo` when neither matches;
  - snapshot files whose blob SHA matches are used; mismatched and missing files (the PNG) are fetched raw, with `via` recorded;
  - `runnable` is true for mode `100755`, under `scripts/`, or starting with `#!`;
  - symbolic links and `../` paths are skipped and listed in `skipped`;
  - `tooLarge` is raised over 10 MB or 500 files;
  - `noSkillFile` is raised when SKILL.md or its `name`/`description` is missing;
  - staging is `<root>/catalog-staging/<previewID>/`, and nothing is written elsewhere;
  - `treeSHA` and `computedHash` of the staged folder equal the tree's.
- [X] T024 [P] [US1] Write `Tests/Catalog/SkillInstallerAddTests.swift` (personal):
  - `add` renames the staged folder to `<home>/.agents/skills/<name>`, then writes the personal lock entry, then the sidecar;
  - a second `add` of the same preview fails with `previewExpired`;
  - `destinationState` is `free`, then `sameSkill(update:false)` after adding;
  - `noPersonalHome` when the root has no personal home.
- [ ] T025 (open: skipped for now, as T013; the scratch walk covered search → preview → add → Shared → Claude link) [P] [US1] Write `Tests/Integration/CatalogAddIntegrationTests.swift`: through a `DaemonCore` with a temporary root and home, call `catalog/search`, `catalog/preview` and `skills/add`. Then `personal/shared` lists the skill with `managed.source`. Then a `FakeACPAgent` session start runs `reconcile`, which places the Claude link `<home>/.claude/skills/<name>`.

### Implementation

- [X] T026 [US1] Write `Src/Catalog/SkillPreviewer.swift`: the steps from research R2 and R3 into a staging folder, filling in `SkillPreview` (data-model.md). Keep at most 8 previews and sweep them after 30 minutes, oldest first. Make T023 pass.
- [X] T027 [US1] Write `Src/Catalog/SkillInstaller.swift`, with `add(previewID:destination:replace:)` for the personal destination only. Follow the order in contracts/catalog-methods.md: move the old folder to the Trash if present, rename the staged folder, write the lock, write the sidecar, putting things back if a step fails. Make T024 pass.
- [X] T028 [US1] Write `Src/Daemon/DaemonCore+Catalog.swift` and implement `catalog/search`, `catalog/preview`, `catalog/destination-state` and `skills/add`. Log the lines from contracts/catalog-methods.md only.
- [X] T029 [US1] Fill in `managed` for each personal skill in `Src/Projects/PersonalDotAgents+Snapshot.swift`, from the personal lock and the sidecar. Make T025 pass.
- [X] T030 [US1] Add `search`, `preview`, `destinationState` and `addSkill` to `App/Catalog/AppModel+Catalog.swift` (an `extension AppModel`, as `App/Hosts/Lending.swift` does), calling the new methods through `client.call`. Hold the sheet's state: query, results, the chosen preview and the destination.
- [X] T031 [US1] Write `App/Catalog/AddSkillSheet.swift` as frame B:
  - title "Add a skill", then the **Add to** segmented control (You / `<project>`), then the search field (300 ms after the last keystroke);
  - one card per result: name, `owner/repo` in monospace, install count on the right, `known` chip, `added` chip;
  - footer "From skills.sh. Choose one to see what is in it before adding." and Cancel.

  Each card is a Button, following the memory note on SwiftUI card taps.
- [X] T032 [US1] Write `App/Catalog/SkillPreviewView.swift` as frame C:
  - "‹ Results" and the skill's name;
  - Owner, Repo, Commit (with the date only when present), Installs and Goes to;
  - the file list, with runnable files marked `script`;
  - the orange script warning;
  - the `ReachDots` for the destination, and the SKILL.md reader;
  - footer "Taken from github.com/<o>/<r> at <commit7>." with Cancel and **Add to ~/.agents** / **Add to <project>**.
- [X] T033 [US1] Change `App/Settings/Shared/SharedSkillsPage.swift` to match frame A:
  - **Add skill…** (the prominent style) in the bar after Reveal in Finder, opening `AddSkillSheet` set to You;
  - a `skills.sh` chip on managed rows;
  - the detail gains **From** (skills.sh · linked `owner/repo`) and **Taken at** (`<commit7> · <age>`, or "not recorded");
  - hand-made skills keep exactly today's buttons.
- [X] T034 [US1] Walk it (quickstart §2, §3 steps 1–5, §4 frames A–C) on a scratch app with the fixture server from T052. Put screenshots beside each frame in `specs/059-marketplace/walk/us1/` and fix any difference from the frames.

**Checkpoint**: a skill found in the app reaches a Claude agent's next start. Commit. This is the MVP.

---

## Phase 4: User Story 2 — Add a skill to a project (P1)

**Goal**: frame D, and the sheet's **Add to** set to a project or worktree.

**Independent test**: quickstart §3 step 6, then frame D on screen.

### Tests first

- [X] T035 [P] [US2] Write `Tests/Catalog/SkillInstallerProjectTests.swift`:
  - `add` to a project writes `<folder>/.agents/skills/<name>` and `<folder>/skills-lock.json`, whose `computedHash` equals the staged folder's;
  - `.agents/skills` is created when missing;
  - `.claude/skills` is linked through `DotAgents` when missing (R7);
  - `git status --porcelain` shows both files untracked, and no commit or index change is made;
  - a worktree folder gets the worktree's own files, not the main checkout's (FR-017).
- [X] T036 [P] [US2] Write `Tests/Catalog/SkillsListTests.swift`: `skills/list` for a project returns every folder with a SKILL.md, with its `description`, and `managed` from `skills-lock.json` plus the sidecar. A project with no `.agents/skills` returns `[]`, not an error.

### Implementation

- [X] T037 [US2] Extend `Src/Catalog/SkillInstaller.swift` to the project destination (project lock, the `.claude/skills` link, `.agents/skills` created) and make T035 pass.
- [X] T038 [US2] Implement `skills/list` in `Src/Daemon/DaemonCore+Catalog.swift` and make T036 pass.
- [X] T039 [US2] Add `projectSkills(folder:)` to `App/Catalog/AppModel+Catalog.swift` (an `extension AppModel`, as `App/Hosts/Lending.swift` does). Reload it when the project page appears and after every add or remove.
- [X] T040 [US2] Write `App/Projects/ProjectSkillsSection.swift` as frame D:
  - the `SectionHeading` "Skills" with a count chip, Reveal in Finder and **Add skill…**;
  - the line "In .agents/skills, committed with the project: everyone who clones it gets these.";
  - a card per skill (name and description; managed ones also show the `skills.sh` chip, `owner/repo · <commit7>` and Remove);
  - an empty state that still offers Add skill….

  Not drawn for a server project (R10).
- [X] T041 [US2] Insert `ProjectSkillsSection` between `WorkflowsSection` and `WorktreesSection` in `App/Projects/ProjectAgentsView.swift`.
- [X] T042 [US2] Make the sheet's **Add to** work both ways in `App/Catalog/AddSkillSheet.swift` and `SkillPreviewView.swift`:
  - opened from a project, it starts set to that project;
  - opened from Settings, the project half lists the person's Mac projects with the selected one first;
  - switching calls `catalog/destination-state` and changes the button wording, the dots and the `added` marks, with no new search (US2 #5).
- [X] T043 [US2] Walk quickstart §3 step 6 and frame D on screen, including a worktree page. Screenshots go in `specs/059-marketplace/walk/us2/`.

**Checkpoint**: adding works both to You and to a project. Commit.

---

## Phase 5: User Story 3 — Update or remove a skill the app added (P2)

**Goal**: frame A's `update` chip, and Update and Remove in both Shared and the project section.

**Independent test**: quickstart §3 steps 8–11.

### Tests first

- [ ] T044 [P] [US3] Write `Tests/Catalog/SkillUpdatesTests.swift`:
  - an unchanged HEAD makes **no** tree request (the stub's log) and moves the sidecar commit on;
  - a moved HEAD with an unchanged folder tree gives `current`;
  - a changed folder gives `available(commit)`;
  - a second check within an hour for the same `source` makes no request (FR-018);
  - a skill the CLI added (no sidecar) is checked by tree SHA alone.
- [ ] T045 [P] [US3] Write `Tests/Catalog/SkillInstallerUpdateRemoveTests.swift`:
  - `update-preview` lists added, changed and removed files against the installed folder;
  - `edited` is true once SKILL.md was changed locally (the hash differs from the lock, R6);
  - `add` with `replace:true` keeps `installedAt` and changes `updatedAt`;
  - `remove` moves the folder to the destination's Trash (`<root>/trash/` in tests), drops the lock and sidecar entries, and is refused for an unmanaged folder;
  - after `remove`, the next `reconcile` sweeps the Claude link.

### Implementation

- [ ] T046 [US3] Write `Src/Catalog/SkillUpdates.swift`, which checks each `source` at most once an hour. Implement `skills/check-updates` in `DaemonCore+Catalog.swift` and make T044 pass.
- [ ] T047 [US3] Add `updatePreview` and `remove` to `Src/Catalog/SkillInstaller.swift`, implement `skills/update-preview` and `skills/remove`, and make T045 pass.
- [ ] T048 [US3] In the app:
  - `App/Settings/Shared/SharedSkillsPage.swift` and `App/Projects/ProjectSkillsSection.swift` call `check-updates` when they appear and show the orange `update` chip;
  - the detail gets **Update** (opening `SkillPreviewView` in update mode, which lists the changed files and warns a second time when `edited`) beside **Remove** (confirmed with "Move <name> to the Trash?");
  - both are offered only when `managed` is set (FR-021).
- [ ] T049 [US3] Walk quickstart §3 steps 8–11 over the socket and the Update/Remove path on screen. Screenshots go in `specs/059-marketplace/walk/us3/`.

---

## Phase 6: User Story 4 — Know when it can't go in (P2)

**Goal**: frame E, and full-or-nothing under failure.

**Independent test**: quickstart §3 steps 7, 12 and 13.

- [ ] T050 [P] [US4] Write `Tests/Catalog/SkillInstallerFailureTests.swift`:
  - `unmanaged` refuses `add` and the folder's hash is unchanged;
  - `managedOther` needs `replace:true`;
  - a failure injected after the rename (the test seam `AGENTS_TEST_CATALOG_PAUSE=afterRename`, or a closure passed into the installer) leaves no folder and no lock entry, and the old folder comes back from the Trash (SC-003);
  - an unreadable personal lock refuses the add before anything moves.
- [ ] T051 [US4] Implement the failure paths in `Src/Catalog/SkillInstaller.swift`, putting things back on each step and honouring the pause seam only when the environment variable is set, and make T050 pass.
- [X] T052 [P] [US4] Write `specs/059-marketplace/walk/fixture-server.py` as quickstart §1 describes. It serves search, download, the ref list, the tree, commits and raw from a fixture git repo it makes under `/tmp`, plus `POST /_advance` and `POST /_down`. **Also needed by T034, so build it before the US1 walk.**
- [ ] T053 [US4] Build frame E's states in `App/Catalog/SkillPreviewView.swift` and `AddSkillSheet.swift`:
  - **unmanaged**: the orange box "You already have a skill called <name> in <folder>. You made it (it didn't come from here), so the app won't replace it…", the blue note when the other destination is free, and Reveal yours plus Cancel;
  - **managedOther**: Replace, with a confirmation;
  - **unreachable**: "Can't reach skills.sh", the explanation line, and Try again, keeping the query;
  - **rateLimited**, **tooLarge**, **noSkillFile** and **notFoundInRepo**: one line each, with Add withheld.
- [ ] T054 [US4] Walk quickstart §3 steps 7, 12 and 13, and frame E on screen. Screenshots go in `specs/059-marketplace/walk/us4/`.

---

## Phase 7: Polish & cross-cutting

- [ ] T055 Interop walk, quickstart §5, on a throwaway `HOME` against the real skills.sh and GitHub:
  - `npx skills add … -g` is shown as managed in the app;
  - an app add is listed by `npx skills list -g`;
  - a project add is listed by `npx skills list` and restored by `npx skills experimental_install` (SC-005).

  Record it in `specs/059-marketplace/walk/interop.md`.
- [ ] T056 [P] Add `docs/how-to/add-a-skill-from-a-catalogue.md`: search, look before adding, You or a project, update and remove, and what "known" means. Add it to `mkdocs.yml` after `share-skills-across-agents.md`.
- [ ] T057 [P] Change `docs/how-to/share-skills-across-agents.md` to link the new how-to as the way in, alongside by hand and `npx skills`.
- [ ] T058 [P] Change `docs/reference/settings.md`: Shared ▸ Skills gains Add skill…, From / Taken at, and Update / Remove for managed skills.
- [ ] T059 [P] Change `docs/explanation/projects-hosts-worktrees.md`: the project page's Skills section, the fact that a worktree has its own `.agents/skills`, and no section on server projects yet.
- [ ] T060 [P] Change `docs/explanation/scoped-tools.md` with a short section on trust: skills.sh does not review what it lists; the app shows everything before adding, marks scripts, and pins the commit.
- [ ] T061 Run `swift test` in full. If anything fails, compare six full runs against main before blaming the branch.
- [ ] T062 Build `Agents` then `Remote` one after the other with `-skipPackagePluginValidation`, and run the Linux gate (`scripts/build-linux-agentsd.sh`) so the `canImport` guards hold.
- [ ] T063 Walk what ships: rerun quickstart §3 and §4 on the final commit of the branch, after merging main into it, before asking Alex for the merge.

---

## Dependencies

- Setup (T001–T006) → Foundational (T007–T022) → every story.
- **US1** (T023–T034) is the MVP and the base for the others. US2, US3 and US4 all use its
  previewer, installer and sheet.
- **US2** (T035–T043) needs US1.
- **US3** (T044–T049) needs US1. It needs US2 only for its project-side UI (T048's section
  half).
- **US4** (T050–T054) needs US1. T052, the fixture server, must be done **before T034**, despite
  its place in the list.
- Polish needs every story.

## Parallel opportunities

- Setup: T002–T005 together.
- Foundational tests T007–T013 together. Then T014–T017, T020 and T021 together, since they are
  separate files. T018 comes before T019 and T022.
- US1: T023, T024 and T025 together. T031 and T032, the two views, can run beside T026–T029 once
  T018's types exist.
- US2: T035 and T036 together.
- US3: T044 and T045 together.
- US4: T050 and T052 together.
- Docs T056–T060 together.

## Implementation strategy

1. **MVP = Phases 1–3.** Search, preview and add to You, visible in Shared, reaching a real
   Claude agent. Walk it against frames A–C and stop to show Alex.
2. **Then US2.** The project section and Add to. With US1 this completes the feature as asked
   ("user or project config").
3. **Then US3 and US4** in either order. Both are P2 and both touch the installer, so do them one
   after the other.
4. **Then Polish.** Interop, docs, the whole suite, and walking what ships. Merge only when Alex
   says it's this lane's turn.
