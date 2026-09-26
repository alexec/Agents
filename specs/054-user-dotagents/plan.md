# Implementation Plan: One Set of Skills and Instructions for Every Agent

**Branch**: `agents/consider-how-might-have` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/054-user-dotagents/spec.md`

## Summary

`~/.agents` becomes the one real copy of the person's skills and instructions. A probe of
every installed runtime on a scratch home ([research.md](research.md) R1) settled what each one
needs. Codex, Grok, Cursor and Copilot already read `~/.agents/skills`, so only Claude gets
per-skill links in `~/.claude/skills`. No runtime reads `~/.agents/AGENTS.md`, so Claude,
Codex, Grok and Copilot each get one instructions link. Cursor has no personal-instructions file.
Gemini (046) is not probed yet and gets nothing until it is.

The daemon reconciles the home at start and before each runtime session, alongside the
project layout's `layOutOnce`. It adopts Claude's real skills and `CLAUDE.md`, never touches
managed folders, and records what it placed so a link the person removed stays removed.
Settings ▸ Agents gets a read-only "Your skills" section fed by a new `personal/skills` method.
The section's look is drawn and approved before it is built.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), as the rest of AgentsKit and the app

**Primary Dependencies**: Foundation `FileManager` only; no new packages

**Storage**: `<root>/personal-layout.json` (placed links, R5); the layout itself is files and
symlinks in the home

**Testing**: `swift test` in `Packages/AgentsKit`, against temporary homes; the quickstart walk on
a scratch root with `AGENTS_PERSONAL_HOME`

**Target Platform**: macOS app and its `agentsd`. The Linux `agentsd` is later (R8).

**Project Type**: desktop app + daemon (existing)

**Performance Goals**: reconcile adds < 50 ms to a session start with 100 skills (SC-005)

**Constraints**: never reach the real home from a scratch root or a test (R4, FR-015); never
write inside managed folders (FR-007); every step its own attempt (FR-012)

**Scale/Scope**: tens to low hundreds of skills; six runtimes

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so it sets no gates. The
project's own standing rules, from memory and earlier specs, are checked instead:

| Rule | How this plan keeps it |
|---|---|
| Settle the UX before building depth | US5's section is drawn as a wireframe and approved before any view code (gate before its tasks) |
| Never touch the real home from tests or scratch | R4: home laid out only on the standard root or an explicit `AGENTS_PERSONAL_HOME`; tests inject the home |
| Never hand Alex a walk you could run | quickstart's walk is run by the implementer on a scratch root, with the probe's sign-in borrowing |
| Main checkout is only main | all work in this worktree |

Re-checked after Phase 1: no change.

## Project Structure

### Documentation (this feature)

```text
specs/054-user-dotagents/
├── proposal.md          # the first write-up, with Alex's decisions
├── spec.md
├── plan.md              # this file
├── research.md          # the probe and the decisions it drove
├── data-model.md
├── quickstart.md
├── contracts/
│   └── personal-skills.md
├── probe/               # run.sh + ask.txt: the R1 probe, rerunnable
└── tasks.md             # /speckit-tasks
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKit/Projects/
├── DotAgents.swift                 # shared helpers (place, attempt, exists) made internal, reused
└── PersonalDotAgents.swift         # NEW: the rule table, adopt, reconcile, skills read model

Packages/AgentsKit/Sources/AgentsKit/Daemon/
├── DaemonCore+PersonalLayout.swift # NEW: which home (R4), record I/O, reconcile hooks, personal/skills
├── DaemonCore+Commands.swift       # call reconcile beside layOutOnce(cwd)
└── Daemon.swift                    # reconcile once at start

Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift
                                    # personalLayout file; AGENTS_PERSONAL_HOME resolution
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift
                                    # personal/skills method + result types

App/Sources/Settings/AgentsSettingsView.swift
                                    # "Your skills" section (after the wireframe gate)
App/Sources/Settings/PersonalSkillsSection.swift   # NEW

Packages/AgentsKit/Tests/AgentsKitTests/
├── PersonalDotAgentsTests.swift    # NEW: every acceptance scenario on a temp home
└── Integration/PersonalLayoutTests.swift  # NEW: daemon start + session start reconcile; scratch root leaves home alone

specs/054-user-dotagents/wireframes/your-skills.svg   # NEW, the US5 gate

docs/how-to/share-skills-across-agents.md   # NEW
docs/explanation/projects-hosts-worktrees.md
docs/reference/runtimes.md
docs/reference/settings.md
```

**Structure Decision**: a sibling of `DotAgents`, not a mode of it. The project layout runs
once per folder and replaces `.claude/skills` with one link. The home layout runs every time,
links per skill, and keeps a record, so the two share helpers but not an entry point. The home
guard in `DotAgents.apply(to:)` stays, which keeps FR-014 true by construction.

## Phases

- **Phase 0 (done):** [research.md](research.md). The probe settled the link table for five
  runtimes; Gemini is left to a task.
- **Phase 1 (done):** [data-model.md](data-model.md),
  [contracts/personal-skills.md](contracts/personal-skills.md), [quickstart.md](quickstart.md).
- **Phase 2:** `/speckit-tasks`. Expected order: core reconcile + tests (US1, US2); adopt
  (US3); record and dangling links (US4); daemon hooks and the scratch-root guard; Gemini probe;
  wireframe gate; Settings section (US5); docs; quickstart walk.

## Complexity Tracking

None.
