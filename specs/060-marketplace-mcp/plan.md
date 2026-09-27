# Implementation Plan: Search the MCP Registry and Add Servers to You or a Project

**Branch**: `agents/060-marketplace-mcp` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/060-marketplace-mcp/spec.md`. Look gate approved as
drawn ([look/](look/README.md)). Secrets and project `mcp.json` decided by Alex, 2026-09-26.

## Summary

059's catalogue sheet gains MCP servers. The daemon talks to the official MCP Registry, turns
an entry into an `mcp.json` fragment with `${NAME}` for secrets, and writes values only to
`~/.agents/secrets.env`. A project gets `.agents/mcp.json`, approved by digest like plugins.

- **Search** (R1): `GET /v0/servers?search=&version=latest`, registry order, publisher + known
  mark on every row.
- **Detail** (R2, R3): `GET /v0/servers/{name}/versions/latest`, then build the exact command
  or URL for the chosen transport (`remote` / `npx` / `uvx` / `docker`).
- **Secrets** (R4, R9): values in `secrets.env` (0600); fill at session start; missing → server
  left out.
- **Write** (R5): splice one entry into personal or project `mcp.json`; sidecar names what the
  app added; hand-written entries untouched.
- **Project** (R6): merge after the app (and agent's chosen) and ahead of personal; waiting
  rows until Approve.
- **UI**: kind switch on 059's sheet (B, C); Add server… on Shared ▸ MCP servers (A) and the
  project section (D); Set… / Remove (E).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), as AgentsKit and the app.

**Primary Dependencies**: Foundation (`URLSession`, `FileManager`), existing
`PersonalDotAgents` MCP parse (054), `SessionServers` (054), `KnownOwners` / `AddSkillSheet`
(059). No new packages.

**Storage**:
- `~/.agents/mcp.json` and `<project>/.agents/mcp.json` (Claude / 054 shape).
- `~/.agents/secrets.env` (new, 0600).
- `<root>/catalog-mcp.json` — sidecar for registry-added servers.
- `<root>/mcp-approvals.json` — digests of approved project entries.

**Testing**: `swift test` in `Packages/AgentsKit`, with a `URLProtocol` stub (or the walk
fixture server) for the registry host. Every test uses a temporary root and temporary personal
home. None reads `$HOME` or reaches the network.

**Target Platform**: the macOS app and its `agentsd`. New methods are control-only. Linux
`agentsd` builds the code but offers nothing new; server projects get no section (R6).

**Project Type**: desktop app + daemon (existing).

**Performance Goals**:
- Results within 2 s of the last keystroke (registry answers well under 1 s; 300 ms debounce).
- Detail within 1 s (one GET).
- Add / Set / Remove are local file writes.

**Constraints**:
- Never put a secret value in `mcp.json`, logs, events, read models or phone messages (FR-004).
- Never overwrite or remove a hand-written entry (R5, R7).
- Never write an unreadable `mcp.json` (FR-008).
- Never reach the real home from a scratch root or a test (FR-010).
- Control-only methods only.

**Scale/Scope**: tens of servers; one sheet kind; about eight daemon methods; two UI surfaces
plus Set/Remove sheets.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template. Gates are the project's
standing rules:

| Gate | Status |
|---|---|
| Settle the UX before building depth: look gate approved before any view code | **Pass**. Frames A–E approved as drawn, 2026-09-26 |
| Every lane in its own worktree off main; the main checkout untouched | **Pass**. `.agents/worktrees/060-marketplace-mcp` |
| A walk never touches the real home or real daemon | **Pass by design**. FR-010, R10 |
| Walk what you ship: scratch Mac app before merge | **Planned**. quickstart §4 |
| Never change code to prove a test; assert the property | **Planned**. Fixture registry, golden `mcp.json` / `secrets.env` |
| Docs written with the feature | **Planned**. Spec Docs list |

Re-checked after Phase 1: no change. Nothing under Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/060-marketplace-mcp/
├── spec.md
├── plan.md              # this file
├── research.md          # R1–R12
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── mcp-methods.md       # daemon methods
│   ├── mcp-json.md          # personal + project files, sidecar, approvals
│   └── secrets-env.md       # secrets.env format and fill rules
├── look/                # approved wireframes A–E
└── checklists/requirements.md
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/
├── AgentsKitCore/Daemon/
│   ├── DaemonAPI+Catalog.swift      # (change) catalog/search gains kind
│   └── DaemonAPI+MCPCatalog.swift   # new: mcp/* methods + Codable types
└── AgentsKit/
    ├── Catalog/
    │   ├── MCPRegistry.swift        # search + detail (R1, R2)
    │   ├── MCPEntryBuilder.swift    # registry → mcp.json fragment (R3, R4)
    │   ├── MCPInstaller.swift       # add / replace / remove, sidecar (R5, R7)
    │   ├── SecretsEnv.swift         # read / write / fill (R4, R9)
    │   ├── MCPApprovals.swift       # project digests (R6)
    │   └── KnownOwners.swift        # (change) domain helpers for publishers (R8)
    ├── Projects/
    │   └── PersonalDotAgents+MCP.swift  # (change) writer; project file path
    └── Daemon/
        ├── DaemonCore+MCPCatalog.swift   # dispatch
        ├── DaemonCore+SessionServers.swift  # (change) project merge + fill (R6, R9)
        └── DaemonCore+Dispatch.swift     # (change) route mcp/*

Packages/AgentsKit/Tests/AgentsKitTests/Catalog/   # MCP* tests beside 059's

App/Sources/
├── Catalog/
│   ├── AddSkillSheet.swift          # (change) kind switch; MCP search/detail
│   ├── MCPServerDetailView.swift    # new (frame C)
│   ├── SetSecretSheet.swift         # new (frame E left)
│   └── RemoveMCPServerSheet.swift   # new (frame E right)
├── Settings/Shared/SharedServersPage.swift  # (change) Add, registry rows, Set/Remove (A)
└── Projects/
    ├── ProjectMCPSection.swift      # new (frame D)
    └── ProjectAgentsView.swift      # (change) section after Skills, before Plugins

docs/  # per the spec's Docs list
```

**Structure decision**: catalogue machinery stays in `Catalog/` beside 059. Session merge and
secret fill stay in the daemon's session path so every start sees them. Nothing in `Remote/`
or `Bridge/` changes.

## Phases for tasks

1. **Secrets and mcp.json writer.** Golden round-trips; fill; refuse unreadable files.
2. **Registry client and entry builder.** Stubbed HTTP; npm / pypi / oci / remote; host call-out.
3. **Install / remove / sidecar / approvals.** Personal and project destinations.
4. **Session merge + fill.** Project ahead of personal; missing secret drops the server.
5. **Daemon methods.** Contracts, control-only, scratch-home resolution.
6. **Sheet kind switch (B, C), Shared (A), project section (D), Set/Remove (E)**, each walked
   against its frame on a scratch app.
7. **Docs.**
