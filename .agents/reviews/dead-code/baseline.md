# Dead-code review baseline

This file records confirmed false positives. Each entry names the analyzer, declaration
or path, and why the code is live. It is empty until the first complete scan confirms a
false positive. Do not add broad suppressions to make a scan quiet.

Tool pins for the first scan:

- Periphery 3.8.0
- `periphery-3.8.0.zip` SHA-256 `07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7`
- `golang.org/x/tools/cmd/deadcode` v0.49.0
- Knip 6.42.1

The Web Knip entry points are `src/main.tsx` and `src/sandbox/proxy.ts`, the two
JavaScript bundles declared in `Web/build.mjs`. Knip does not infer these API-based
esbuild entries, so `Web/knip.json` names them. The analyzer configuration has no ignores.

## Confirmed false positives

Added 2026-10-27 (first run, `2026-10-27.md`).

### deadcode (Go)

- `Go/internal/agentsd/wake.go` `(*waker).Settings`, `Go/internal/controllink/hostkey.go`
  `HostKeyService`, and in `Go/internal/mac/` `power.go` (`ReadPower`, `HoldAwake`,
  `Hold.Release`), `signin/claude.go` (`NewClaude`, `readKeychain`, `askTheMacsClaude`,
  `isExecutable`, `loginPath`) and `signin/relays.go` (`Relays.SignIn`, `Grant`, `Port`,
  `Stop`, `write`): unreachable only in a linux scan. Their callers are in `_darwin.go`
  files; the `GOOS=darwin` scan reaches them. Scan with `GOOS=darwin` as well before
  reading any `internal/mac` finding.

### Knip (Web)

- Any export of `Web/src` that a `Web/test/*.test.mjs` file names: the tests bundle the
  source with `test/load.mjs` and read exports by name, which Knip does not follow.
  Knip lists them as unused exports. Not ignored in `knip.json` (it would hide real
  findings); filter them when reading the output.

### Compatibility search

- `Go/internal/agentsd/guarded.go` (the loop after "A file the app no longer keeps"):
  drops a record for any path that is not guarded; the general rule, live.
- `Packages/AgentsKit/Sources/AgentsKitCore/Model/Folder.swift` `unknownFields`: forward
  compatibility between machines on different versions; not migration code.
- "A host (or daemon) too old to know the method": a client and a host of different
  versions, which is live in v0.x; not migration code.
