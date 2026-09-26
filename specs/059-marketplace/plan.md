# Implementation Plan: Search a Catalogue and Add Skills to You or a Project

**Branch**: `agents/059-marketplace` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/059-marketplace/spec.md`. Look gate approved as drawn
([look/](look/README.md)).

## Summary

The daemon gets a small catalogue client and an installer, and the app gets one sheet and one
project section.

- **Search** (R1): skills.sh `/api/search`, GitHub sources only, shown most installed first.
- **Preview** (R2, R3):
  - The daemon reads the repo's HEAD commit from git's ref list, which has no rate limit.
  - It takes that commit's tree from GitHub as the file list.
  - It fills in each file from the skills.sh snapshot, checked against the file's git blob hash,
    and fetches anything missing or different from `raw.githubusercontent.com` at the commit.
  - Everything goes into a staging folder the daemon owns.

  One GitHub API call per preview, through `gh api` when it is signed in (R4). When GitHub is
  rate-limited, the daemon downloads a tarball of the commit instead.
- **Add** (R5, R7): the staged folder is moved into `~/.agents/skills/<name>` or
  `<folder>/.agents/skills/<name>` in one step. The `skills` CLI's own lock file is written in the
  CLI's shape, plus a sidecar in the daemon's root for the commit. 054's `reconcile` and the
  dotagents layout then carry the skill to every runtime, with no new wiring.
- **Update / Remove** (R5, R6, R9): manageable means named in a lock entry.
  - The update check first compares HEAD with the recorded commit, and makes a tree call only
    when HEAD has moved.
  - A locally edited skill is found by recomputing the hash its lock uses.
  - Remove and Replace move the old folder to the Trash.
- **UI**:
  - The Add sheet, with frames B, C and E.
  - Add skill…, a source row, and Update and Remove in Shared ▸ Skills (A).
  - A Skills section on the project page between Workflows and Worktrees (D). It is left out on
    server projects (R10).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), as the rest of AgentsKit and the app.

**Primary Dependencies**: Foundation (`URLSession`, `FileManager`, CryptoKit for SHA-1 and
SHA-256), the existing `GitHubCLI` (038), and `/usr/bin/tar` for the rate-limit fallback only. No
new packages.

**Storage**:
- The two lock files, in the CLI's shape (`~/.agents/.skill-lock.json` and
  `<folder>/skills-lock.json`).
- `<root>/catalog-skills.json`, the sidecar, holding commit, date and tree SHA.
- `<root>/catalog-staging/<previewID>/`, previews, removed after 30 minutes or once used.

**Testing**: `swift test` in `Packages/AgentsKit`, with a `URLProtocol` stub for the three hosts
and a fake `gh`. Golden hashes come from `node` (the CLI's algorithm) and from `git write-tree`
(tree SHA). The quickstart walk runs on a scratch root with `AGENTS_PERSONAL_HOME` and a local
fixture server (`AGENTS_TEST_CATALOG_URL`, `AGENTS_TEST_GITHUB_URL`).

**Target Platform**: the macOS app and its `agentsd`. The new methods are control-only. The
Linux `agentsd` builds with the code (it is `canImport(FoundationNetworking)`-safe) but offers
nothing new, and server projects get no section (R10).

**Project Type**: desktop app + daemon (existing).

**Performance Goals**:
- Results within 2 s of the last keystroke (SC-002). skills.sh answers in well under 1 s, and
  the app waits 300 ms before sending.
- A preview within 3 s for a typical skill (under 60 files).
- Add is a rename, instant.

**Constraints**:
- Write to a destination in full or not at all (FR-009).
- Never touch a skill with no lock entry (FR-013, SC-004).
- Never reach the real home from a scratch root or a test (FR-024).
- No symbolic links, no paths outside the folder, at most 10 MB and 500 files (FR-014).
- Keep every key in the lock files that the app doesn't own (R5).
- Send only the query and the repository's name out (FR-023).

**Scale/Scope**: tens of added skills; one sheet; four daemon methods and two list methods.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template, so no principles have been
ratified. The gates are the rules this project keeps (AGENTS.md, and the team's standing
feedback):

| Gate | Status |
|---|---|
| Settle the UX before building depth: look gate approved before any view code | **Pass**. Frames A–E approved as drawn, 2026-09-26 |
| Every lane in its own worktree off main; the main checkout untouched | **Pass**. `.agents/worktrees/059-marketplace` |
| A walk never touches the real home or real daemon (scratch root, `AGENTS_PERSONAL_HOME`) | **Pass by design**. FR-024, the test hooks in R8 |
| Walk what you ship: the exact commit on a scratch Mac app before merge | **Planned**. quickstart §4 |
| Never change code to prove a test; assert the property | **Planned**. Golden tests, fixture server |
| Docs written with the feature | **Planned**. The spec's Docs list |

Re-checked after Phase 1: no change. Nothing needs justifying under Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/059-marketplace/
├── spec.md
├── plan.md              # this file
├── research.md          # R1–R11
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── catalog-methods.md   # the daemon methods
│   └── lock-files.md        # the two lock files and the sidecar, byte for byte
├── look/                # approved wireframes A–E
└── checklists/requirements.md
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/
├── AgentsKitCore/Daemon/
│   └── DaemonAPI+Catalog.swift        # methods + Codable types (contracts/catalog-methods.md)
└── AgentsKit/
    ├── Catalog/                        # new
    │   ├── SkillsCatalog.swift         # skills.sh search + snapshot (R1, R3)
    │   ├── GitHubSource.swift          # ref list, tree (gh or anonymous), raw, tarball fallback (R3, R4)
    │   ├── SkillPreviewer.swift        # finds the folder, stages the files, checks size/links/paths (R2, R3, FR-014)
    │   ├── SkillInstaller.swift        # add / replace / update / remove, the atomic move, Trash (FR-009, R9)
    │   ├── SkillLocks.swift            # the two CLI lock files + the sidecar (R5)
    │   ├── SkillHashes.swift           # git blob/tree SHA-1, CLI computedHash (R5, R6)
    │   └── KnownOwners.swift           # R11
    └── Daemon/
        ├── DaemonCore+Catalog.swift    # dispatch; staging lifetime; update-check throttle
        └── DaemonCore+Dispatch.swift   # (change) route catalog/* and skills/*
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/ConnectionRole.swift  # (no change) new methods are control-only by omission
Packages/AgentsKit/Tests/AgentsKitTests/Catalog/                      # new, one file per source file above

App/Sources/
├── Settings/Shared/SharedSkillsPage.swift   # (change) Add skill…, source rows, Update/Remove (frame A)
├── Catalog/                                  # new
│   ├── AddSkillSheet.swift                   # search → detail → add; Add to switch (B, C, E)
│   └── SkillPreviewView.swift                # the detail's left column and the SKILL.md reader
├── Projects/ProjectSkillsSection.swift       # new (frame D)
├── Projects/ProjectAgentsView.swift          # (change) section between Workflows and Worktrees
└── Catalog/AppModel+Catalog.swift            # calls, per-destination "added" names

docs/  # per the spec's Docs list
```

**Structure decision**: the machinery lives in AgentsKit's new `Catalog/` folder and is used only
by the daemon, beside `Projects/PersonalDotAgents*`. The app has one new folder for the sheet.
Nothing in `Remote/` or `Bridge/` changes.

## Phases for tasks

1. **Hashes and locks.** Golden tests first, then `SkillHashes` and `SkillLocks`, including
   round-tripping a real `~/.agents/.skill-lock.json` with keys the app doesn't own.
2. **Sources.** `GitHubSource` and `SkillsCatalog` against the `URLProtocol` stub, covering: the
   ref list, the tree, raw, a snapshot mismatch, missing binaries, rate-limit → tarball, `gh`
   present or absent.
3. **Preview and install.** Staging, the checks from FR-014, the atomic move, clash rules
   (FR-013), Trash, and interrupted writes (SC-003).
4. **Daemon methods.** Contracts, dispatch, staging lifetime, update throttle, scratch-home
   resolution.
5. **The sheet (B, C, E), then Shared (A), then the project section (D)**, each walked on a
   scratch app against its frame.
6. **Interop walk** with the real `npx skills` on a scratch `HOME` (SC-005), then docs.
