# Tasks: Search the MCP Registry and Add Servers to You or a Project

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/mcp-methods.md](contracts/mcp-methods.md),
[contracts/mcp-json.md](contracts/mcp-json.md), [contracts/secrets-env.md](contracts/secrets-env.md),
[quickstart.md](quickstart.md), [look/](look/README.md) (approved by Alex, 2026-09-26, as drawn)

**Tests**: Included. This repo tests every daemon behaviour, and the quickstart names each
property. Write each test before the code that makes it pass.

- Network tests use a `URLProtocol` stub (extend `Tests/Support/CatalogStub.swift` or add
  `MCPRegistryStub.swift`), following `Tests/Unit/CredentialCheckTests.swift`.
- Every test uses a temporary root and a temporary personal home. None reads `$HOME` or
  reaches the network.

**Where**: `.agents/worktrees/060-marketplace-mcp` on `agents/060-marketplace-mcp`. Never edit
the shared checkout. Paths:

| Short form | Means |
|---|---|
| `Pkg/` | `Packages/AgentsKit/` |
| `Src/` | `Pkg/Sources/AgentsKit/` |
| `Core/` | `Pkg/Sources/AgentsKitCore/` |
| `Tests/` | `Pkg/Tests/AgentsKitTests/` |
| `App/` | `App/Sources/` |

New App files need `xcodegen generate` after adding.

**Rules this feature must keep**:

- **Never a secret value** in `mcp.json`, logs, events, read models or phone messages (FR-004).
- **Never touch a hand-written entry.** Only sidecar-named servers are replaced or removed (R5, R7).
- **Unreadable `mcp.json` → no write** (FR-008).
- **Missing `${NAME}` → server left out of the session**, not started empty (FR-005, R9).
- **Never the real home.** Scratch root / tests use `AGENTS_PERSONAL_HOME` (FR-010).
- **Control-only.** `mcp/*` and the extended `catalog/search` stay out of `deviceMethods` and
  `agentMethods`.
- **Views match** frames A–E as approved.

**Order**:
1. Secrets + mcp.json writer.
2. Registry client + entry builder.
3. US1 MVP: preview → add to You → sheet + Shared.
4. US2: projects, approval, merge order.
5. US3: Set secret, Remove.
6. Polish: walk + docs.

---

## Phase 1: Setup

- [X] T001 Create `Src/Catalog/` additions as needed, `Tests/Catalog/Fixtures/mcp/`,
  `App/Catalog/` MCP views folder usage, and `specs/060-marketplace-mcp/walk/`; run
  `xcodegen generate` and confirm `xcodebuild -scheme Agents -skipPackagePluginValidation build`
- [X] T002 [P] Record trimmed real registry responses under `Tests/Catalog/Fixtures/mcp/http/`:
  - search `github` (first page, mix of remotes + packages);
  - detail `io.github.github/github-mcp-server` (remote + oci);
  - detail `io.github.upstash/context7` (remote + npm + secrets);
  - detail `io.github.gitHubDujianfeng/duke-book` (npm + required secret);
  - a Smithery remote whose host is not the publisher's;
  - a 503 body for offline.
- [X] T003 [P] Write `specs/060-marketplace-mcp/walk/fixture-server.py` serving those fixtures on
  `/v0/servers` and `/v0/servers/{name}/versions/latest`, plus `POST /_down`
- [X] T004 [P] Extend `Tests/Support/CatalogStub.swift` (or add `MCPRegistryStub.swift`) so tests
  can point `AGENTS_TEST_MCP_REGISTRY_URL` / injected base URL at fixture responses and record
  requests

---

## Phase 2: Foundational (blocks every story)

**Purpose**: secrets.env, mcp.json splice writer, sidecar, registry client, entry builder, wire
types. Every story uses them.

- [X] T005 [P] Write failing tests in `Tests/Catalog/SecretsEnvTests.swift` for
  `contracts/secrets-env.md`: round-trip `KEY=value`, values with `=`, preserve foreign lines,
  mode 0600 on create, names-only listing
- [X] T006 Implement `Src/Catalog/SecretsEnv.swift` to make T005 pass
- [X] T007 [P] Write failing tests in `Tests/Catalog/MCPJSONWriterTests.swift`: splice one entry
  keeping key order and hand-written siblings; refuse invalid JSON; project path
  `<folder>/.agents/mcp.json`
- [X] T008 Implement writer helpers on `PersonalDotAgents` (in
  `Src/Projects/PersonalDotAgents+MCP.swift` or a sibling) to make T007 pass
- [X] T009 [P] Write failing tests in `Tests/Catalog/MCPSidecarTests.swift` for
  `<root>/catalog-mcp.json` add / remove / lookup by destination+name
- [X] T010 Implement sidecar load/save beside the other Catalog types
- [X] T011 [P] Write failing tests in `Tests/Catalog/MCPRegistryTests.swift`: search order, detail
  encoding of `/` in the name, unreachable, empty query skips network
- [X] T012 Implement `Src/Catalog/MCPRegistry.swift` (R1, R2) against the stub
- [X] T013 [P] Write failing tests in `Tests/Catalog/MCPEntryBuilderTests.swift` for R3/R4:
  remote→http with `${NAME}`; npm→`npx -y id@ver`; pypi→`uvx`; oci→`docker run`; skip mcpb;
  Smithery host call-out; short `nameHere` from title
- [X] T014 Implement `Src/Catalog/MCPEntryBuilder.swift` (+ publisher/`known` helpers on
  `KnownOwners` / CatalogEndpoints) to make T013 pass
- [X] T015 [P] Add Codable types and method names from `contracts/mcp-methods.md` to
  `Core/Daemon/DaemonAPI+MCPCatalog.swift`; extend `catalog/search` with `kind` in
  `DaemonAPI+Catalog.swift`; assert none of the new methods are in `deviceMethods` /
  `agentMethods` (`Tests/Unit/ConnectionRoleTests.swift` or Catalog equivalent)

**Checkpoint**: foundation ready — US1 can start.

---

## Phase 3: User Story 1 — Add a server for every agent you start (P1) 🎯 MVP

**Goal**: Search the registry, preview, add to `~/.agents` with secrets in `secrets.env`, see it
on Shared ▸ MCP servers, and have the next session receive it filled in.

**Independent test**: quickstart §2 rows 1–4 on a scratch root.

- [ ] T016 [P] [US1] Write failing tests in `Tests/Catalog/MCPPreviewAndAddTests.swift`: preview
  builds entry; add writes mcp.json + secrets.env + sidecar; session fill substitutes `${NAME}`;
  missing secret drops the server
- [ ] T017 [US1] Implement `Src/Catalog/MCPInstaller.swift` (add / replace personal) and fill
  logic used by session start (`SecretsEnv.fill`)
- [ ] T018 [US1] Change `Src/Daemon/DaemonCore+SessionServers.swift` to fill `${NAME}` on personal
  servers before `plan` (project merge comes in US2); log drops by name only
- [ ] T019 [US1] Implement `Src/Daemon/DaemonCore+MCPCatalog.swift` for `mcp/preview`, `mcp/add`
  (personal), and `catalog/search` with `kind:"mcp"`; route in `DaemonCore+Dispatch.swift`
- [ ] T020 [US1] Change `App/Catalog/AddSkillSheet.swift` for the Skills | MCP servers kind
  switch (frame B): MCP search rows with publisher, known, runs, remoteHost
- [ ] T021 [US1] Add `App/Catalog/MCPServerDetailView.swift` (frame C): Run with, entry preview,
  secret fields, Add disabled until required secrets filled or already set
- [ ] T022 [US1] Change `App/Settings/Shared/SharedServersPage.swift` (frame A): **Add server…**,
  registry chip + version, set/missing, Remove only when managed (Remove UI can be stubbed until
  US3 if needed — prefer wiring remove call once T028 exists; until then hide Remove)
- [ ] T023 [US1] Walk frame A–C on a scratch app with the fixture registry; notes in
  `specs/060-marketplace-mcp/walk/us1/README.md`

**Checkpoint**: US1 works alone — add for You end to end.

---

## Phase 4: User Story 2 — Add a server to a project (P1)

**Goal**: Project `.agents/mcp.json`, approval by digest, merge ahead of personal, Set… for
missing secrets on the project page.

**Independent test**: quickstart §2 rows 5–7.

- [ ] T024 [P] [US2] Write failing tests in `Tests/Catalog/MCPProjectTests.swift`: add to project
  auto-approves; hand-written entry waits; approve with digest; merge order project before
  personal; missing secret listed and omitted from session
- [ ] T025 [US2] Implement `Src/Catalog/MCPApprovals.swift` and wire approve into installer +
  `mcp/list` / `mcp/approve`
- [ ] T026 [US2] Change `DaemonCore+SessionServers.swift` merge order per
  `contracts/mcp-json.md` (app → chosen → project approved → personal → plugins)
- [ ] T027 [US2] Add `App/Projects/ProjectMCPSection.swift` and insert it in
  `ProjectAgentsView.swift` after Skills, before Plugins (frame D); sheet opens with project
  destination; skip section on server projects
- [ ] T028 [US2] Walk frame D; notes in `specs/060-marketplace-mcp/walk/us2/README.md`

**Checkpoint**: US1 + US2 both work.

---

## Phase 5: User Story 3 — Remove, and set a secret (P2)

**Goal**: Set… / Replace… for secrets; Remove with optional forget-secret when unused.

**Independent test**: quickstart §2 rows 8–9; frame E.

- [ ] T029 [P] [US3] Write failing tests in `Tests/Catalog/MCPRemoveSecretTests.swift`: set-secret;
  remove managed; refuse remove unmanaged; forgetSecret only when unused; refuse when still
  referenced
- [ ] T030 [US3] Implement `mcp/set-secret` and `mcp/remove` in `DaemonCore+MCPCatalog.swift` +
  installer
- [ ] T031 [US3] Add `App/Catalog/SetSecretSheet.swift` and `RemoveMCPServerSheet.swift` (frame E);
  wire Set… / Replace… / Remove… from Shared and the project section
- [ ] T032 [US3] Walk frame E and offline (quickstart row 10); notes in
  `specs/060-marketplace-mcp/walk/us3/README.md`

**Checkpoint**: all three stories independently usable.

---

## Phase 6: Polish

- [ ] T033 [P] Write `docs/how-to/add-an-mcp-server-from-the-registry.md`
- [ ] T034 [P] Update `docs/how-to/share-skills-across-agents.md` for `secrets.env` / `${NAME}`
  and link the new how-to
- [ ] T035 [P] Update `docs/reference/settings.md` (Add server…, Remove, Set…)
- [ ] T036 [P] Update `docs/explanation/projects-hosts-worktrees.md` for project servers,
  approval, whose secrets
- [ ] T037 Write `specs/060-marketplace-mcp/checklists/requirements.md` confirming spec quality
  after look + plan
- [ ] T038 Run quickstart §2 end to end on a scratch root; record in
  `specs/060-marketplace-mcp/walk/final.md`
- [ ] T039 Confirm `swift test` (Catalog / MCP filters) green and the Mac app scheme builds

---

## Dependencies & execution order

- Phase 1 → Phase 2 → US1 → US2 → US3 → Polish.
- US2 depends on US1's installer and session fill.
- US3 depends on sidecar + list from US1/US2.
- Within a phase, [P] tasks are different files and can proceed together once their
  prerequisites in that phase are done.

## Parallel example (Phase 2)

```text
T005 SecretsEnv tests  ||  T007 MCPJSON writer tests  ||  T009 sidecar tests
T011 registry tests    ||  T013 entry-builder tests   ||  T015 API types
```

## MVP

Phases 1–3 (US1 only): search, preview, add to You, Shared ▸ MCP servers, session fill.

## Task count

39 tasks (T001–T039). US1: T016–T023. US2: T024–T028. US3: T029–T032. Polish: T033–T039.
