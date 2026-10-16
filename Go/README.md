# Go

The daemon (`agentsd`) and the control plane (`agents-control`) as they move from Swift
to Go (#1134). One module, so the two share the wire types and the control exchange.
The Mac window, the Remote, `Shared/UI`, the web page, Agents Host and `agents-relay` do
not move.

| Path | What | Area |
|---|---|---|
| `wire/` | The wire types: `*_gen.go` made from `Packages/Wire/` by `scripts/wire.sh gen`, the meaning-types by hand | build |
| `cmd/wiregen/` | Makes `wire/*_gen.go` and `Web/src/protocol/generated.ts` from `Packages/Wire/` | build |
| `internal/buildinfo/` | The version and the implementation (`go`) | build |
| `cmd/agentsd/`, `internal/agentsd/` | The host daemon | hosts |
| `cmd/agents-control/`, `internal/controlplane/` | The control plane | control-plane |
| `internal/controllink/` | Both sides of the host ↔ control plane exchange | control-plane |
| `internal/safe/` | Recover helpers: one panic never takes a host or the control plane down | build |

## Building and testing

On the Mac, Go runs in a `golang` container (Go is not installed here); the caches are in
`~/Library/Caches/Agents-build/go`. Lease "build" first.

```sh
Go/scripts/go.sh vet ./...
Go/scripts/go.sh test ./...
```

CI's `go` job builds, vets and tests the module on Linux on any change under `Go/`, and
`scripts/select-test-suites.sh` runs no Swift suite or macOS job for a change under `Go/`
alone. The merge wave runs the same as `test-go`.

The rules (#1134): no cloud login is ever required, plain files only (no SQLite or other
embedded database), and today's file layout, so a change of language keeps every agent,
host and member.
