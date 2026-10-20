# Implementation Plan: Capabilities decide, versions inform

**Branch**: `agents/work-github-issue-1748` | **Date**: 2026-10-20 | **Spec**: [spec.md](spec.md)
**Input**: [spec.md](spec.md), issue #1748

## Summary

The schema names a capability for each method and notification. The generator makes the
constants and a method → capability table for Go, Swift and TypeScript. Each peer sends its
list when it connects; the control plane keeps each host's list, compares lists with its
required sets, and gives the lists to the clients. The clients gate the features that came
after 0.5 on one `has` check. The version string comes from the tag, in SemVer.

## Technical Context

**Language/Version**: Go 1.x (`Go/`, through `Go/scripts/go.sh`), Swift 6 (AgentsKit, App,
Remote, Shared/UI), TypeScript (`Web/`)
**Primary Dependencies**: none new
**Storage**: the control plane's host records keep the last list (`records`)
**Testing**: `scripts/wire.sh check`, Go tests, `WireSchemaTests`, `Web/test/*.test.mjs`, run-app walks
**Target Platform**: macOS (window, host), iOS/iPadOS (Remote), browsers (web page), Linux (`agentsd`, `agents-control`)
**Constraints**: every new wire field is optional; a peer from before this feature works as today

## Constitution Check

- **I. Spec-led:** this spec, plan and tasks first. ✓
- **II. Capability-driven:** the feature is that rule, for the wire. ✓
- **III. Scoped access:** no new access. A client's list is not a grant; a refusal names only
  capability names and a version. ✓
- **IV. Inspectable:** Settings shows each part's version and what a host is missing. ✓
- **V. Docs and quality:** `docs/explanation/versions.md` and tests in each PR. ✓

## Project Structure

```text
Packages/Wire/{daemon,control}.openrpc.json      x-capability on each method
Packages/Wire/daemon.schema.json                  the new optional fields (PR 2)
Go/cmd/wiregen/capabilities.go                    reads x-capability, writes the three files
Go/wire/capabilities_gen.go                       generated
Web/src/protocol/capabilities.generated.ts        generated
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/Capabilities.generated.swift   generated
Go/internal/agentsd, Go/internal/controlplane, Go/internal/controllink   lists, required sets, -32008 (PR 2)
App/Sources, Remote/Sources, Shared/UI, Web/src  has(), gates, Settings (PR 3)
scripts/version.sh and the build scripts          SemVer (PR 4)
docs/explanation/versions.md                      the rule (PR 1)
```

## The PRs, one after another in this lane

1. **Schema (US4).** `x-capability` on every method; wiregen reads it, refuses a method without
   it, and writes the three generated files; `WireSchemaTests` checks that each method Swift
   calls has a capability; `docs/explanation/versions.md`; this spec.
   `mac: docs only, remote: docs only, web: docs only` (no UI change).
2. **Handshake (US2, US3 Go side).** The new optional fields; `agentsd` and `agents-control` make
   their lists; the uplink sends the host's; the control plane stores it, sets `needsUpdate`,
   answers `-32008`, and gives lists in `control/status` and `hosts/list`. Swift and the web
   page send `client.wire/1` in `ControlAuth`.
3. **Clients (US1, US2 UI).** `has` on each client's model of a host; the gates; Settings shows
   versions and "Needs an update". All three clients; `parity.md` gets a row.
4. **Versions (US5).** `scripts/version.sh`; every build script and the web manifest use it; the
   release skill checks agreement and writes capability changes in the notes.

## Complexity Tracking

None. The held audit PR #1752 will need `x-capability` on its new methods when it lands; this
lane comments on it once PR 1 merges.
