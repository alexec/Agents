# Tasks: Capabilities decide, versions inform (#1748)

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/capabilities.md](contracts/capabilities.md)

## Phase 1: Schema, PR 1 (US4) 🎯 first

- [x] T001 [US4] Add `"x-capability"` after each method's `"name"` in `Packages/Wire/daemon.openrpc.json` and `Packages/Wire/control.openrpc.json` (research R1, R3)
- [x] T002 [US4] Read `x-capability` in `Go/cmd/wiregen/schema.go`; fail on a missing or bad value, with the method's name
- [x] T003 [US4] Write `Go/wire/capabilities_gen.go`, `Web/src/protocol/capabilities.generated.ts` and `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/Capabilities.generated.swift` in `Go/cmd/wiregen/capabilities.go`; add them to `-check`
- [x] T004 [US4] Tests in `Go/cmd/wiregen/main_test.go`: a missing and a bad `x-capability` fail; the table has each method
- [x] T005 [US4] `WireSchemaTests`: each `DaemonAPI` method name Swift sends has a capability in `Capability.host` or `Capability.control`
- [x] T006 [US4] `docs/explanation/versions.md` (the rule) and a line in `Packages/Wire/README.md`; link from `docs/explanation/index.md`
- [x] T007 Run `scripts/wire.sh gen`, the wiregen tests, `WireSchemaTests`, `scripts/lint.sh`; PR, auto-merge

## Phase 2: Handshake, PR 2 (US2, US3)

- [x] T010 [US2] Schema: `capabilities` on `HostHello`, `ControlAuth`, `ControlHost`; `capabilities` and `required` on `ControlStatus`; `missing` on `ControlHost`; `gen`
- [x] T011 [US2] `Go/wire`: `Has(list, cap)` and `ListFor(table, served)` helpers, with tests
- [x] T012 [US2] `agentsd`: its list from `d.handlers` + declared; sent in `host/hello` (`Go/cmd/agentsd/main.go`)
- [x] T013 [US2] Control plane: store a host's list on its record; `missing` and `needsUpdate` against the host required set; `capabilities` on `ControlHost`; `control/hostChanged` when it changes
- [x] T014 [US3] Control plane: a client's list from `ControlAuth`; `-32008` with `missing`/`update` for each call but `control/status`; none for a client with no list
- [x] T015 [US2] `control/status`: the control plane's own list and its required sets
- [x] T016 [US3] Swift and web clients send `client.wire/1` in `ControlAuth`; `WireSchemaTests` for the new fields
- [x] T017 Tests: generated list = registered methods (agentsd, control plane); needsUpdate; -32008; golden wire file; PR, auto-merge

## Phase 3: Clients, PR 3 (US1, US2)

- [x] T020 [US1] `has(_:)` on the host model in AgentsKit (Mac, Remote) and in `Web/src/model` (true when no list)
- [x] T021 [US1] Gate on all three: Branch from Here (`chat.branch/1`), find (`agents.find/1`), said search (`agents.said/1`), edit a queued prompt (`agents.edit-queued/1`), Connections (`connections/1`), connector set-up (`connectors.setup/1`), file completion and diagnostics (`files.complete/1`, `files.diagnostics/1`), Made by agents (`mcp.made-by-agents/1`), Simulators (`simulators/1`); "This host needs an update to do this"
- [x] T022 [US2] Settings ▸ Control plane on the Remote and the web page: the control plane's version and each host's; "Needs an update" with the missing names on all three
- [x] T023 [US3] "Update this app" in Settings on all three, from `control/status.required.client` against the app's own list (`control/status` is never refused, so no error needs catching)
- [x] T024 Tests (web `node --test`, AgentsKit), `parity.md` row; PR with parity lines, auto-merge. The walk on a scratch set-up waits for one that runs an older host

## Phase 4: Versions, PR 4 (US5)

- [ ] T030 [US5] `scripts/version.sh`: rule 8, with a test for a tag and a commit after it
- [ ] T031 [US5] `scripts/go-agentsd.sh`, `scripts/go-control.sh`, `scripts/build-linux-agentsd.sh`, the web manifest and local `MARKETING_VERSION` use it
- [ ] T032 [US5] Release skill: check the parts agree; capabilities added, deprecated and removed in the notes
- [ ] T033 PR, auto-merge; file `hosts/update` and the CI skew test; close #1748

## Dependencies

Phase 1 → Phase 2 → Phase 3. Phase 4 needs only Phase 1's doc, and goes last to keep one PR open at a time.
