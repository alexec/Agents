# Tasks: Enterprise T8, data governance

**Input**: `spec.md`, `plan.md` in `specs/1001-data-governance/`.

**Format**: `[ID] [P?] [Story] Description`. Each phase is one slice of `plan.md`, one pull request. Write the tests first.

## Phase 1: a1, redaction (area: hosts)

- [x] T001 [US1] Test `redact.Text` and `redact.Bytes`: each token shape becomes `[redacted:<kind>]`; plain text, hashes and UUIDs do not change; a JSON line stays valid, in `Go/internal/agentsd/redact/redact_test.go`.
- [x] T002 [US1] Test that a transcript entry with a GitHub token is stored redacted, and the entry the caller gets back is redacted, in `Go/internal/agentsd/store/store_test.go` (SC-001).
- [x] T003 [US1] Test that a log line with a token is written redacted, in `Go/cmd/agentsd/main_test.go` (SC-001).
- [x] T004 [US1] Add `Go/internal/agentsd/redact/redact.go`.
- [x] T005 [US1] Redact in `store.AppendMany`; decode a changed line back into the entry.
- [x] T006 [US1] Redact in `logLine.Write`, and in `app-tools.jsonl` (`assess.go`).
- [x] T007 Update `docs/explanation/compliance/` (redaction is built).

## Phase 2: b1, erasure (area: hosts)

- [x] T008 [US2] Test that Delete of an archived Claude agent leaves no session file in a scratch `CLAUDE_CONFIG_DIR`, and none for Codex in a scratch `CODEX_HOME`, in `Go/internal/agentsd/erasure_test.go` (SC-002).
- [x] T009 [US2] Test the queue: bounded to 1,000, kept across a restart, dropped after 3 tries.
- [x] T010 [US2] Test that a restore skips an erased agent (SC-003).
- [x] T011 [US2] Add `Go/internal/agentsd/erasure.go`: the queue, the eraser, the files fallback, the erased list.
- [x] T012 [US2] Queue from `deleteArchived`; `runtimeCopy` on `agent.deleted`; skip in `restoreAgent`.
- [x] T013 Update `docs/explanation/compliance/` (erasure is built).

## Phase 3: a2, chunk seams (area: hosts)

- [x] T014 [US1] Hold back a trailing run of token characters in an agent message chunk (at most 256 bytes) until the next chunk, a different update or the turn's end; test a GitHub token split over two chunks.

## Phase 4: a3, the control plane's log (area: control-plane)

- [x] T015 `controlplane/log.go` `Redact` also runs `redact.Text`.

## Phase 5: c1 and c2, export and import (areas: hosts; sidebar, projects)

- [x] T016 [US3] `agents/export {agentID | project}` and `agents/import` in `Packages/Wire`; `scripts/wire.sh gen`.
- [x] T017 [US3] Daemon: write the backup format for the chosen agents; import as restore does.
- [x] T018 [US3] Export… and Import… in the agent and project menus, on the Mac, the Remote and the web page; parity rows.

## Phase 6: d1 to d3, chain and sinks (areas: reports, control-plane)

- [x] T019 [US4] `seq` and `prev` on each audit entry, one chain for each copy; a seal for each day; `agents-control audit verify`; test one changed and one removed entry.
- [x] T020 [US4] Syslog (RFC 5424, TCP or TLS) and HTTP (JSON lines) sinks; a queue of 10,000, oldest out, with a count of the dropped.
- [x] T021 [US4] Console ▸ Audit ▸ Sinks on the web page.
