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

## The control plane (`agents-control`, #1137)

The Go `agents-control` takes the Swift one's command line (`serve`, `serve --home`,
`code`, `hosts`, `clients`, `install-script`, `store check`, `version`) and reads and
writes today's `control/` folder: the store, `control-key` (or the key on `--key-fd`),
and `tls/`, so its certificate's pin is the one every member holds. Every one of the
61 control-plane methods is answered; the handover's copy side is there too, so Agents
Host's *Move to another machine* and *Relay for my devices* work with it.

| Package | What it ports |
|---|---|
| `controlplane/` | `ControlService`, `ControlRouter`, `ControlMethods`, `ControlCodes`, `CopyMesh`, `Leases`, `Handover`, `HostCopies`, `StoreSweep`, `ControlLog` |
| `controlplane/store`, `s3store` | The folder store (the default) and the bucket (an option) |
| `controlplane/records` | `ControlRecords`, in today's JSON |
| `controlplane/kms` | The key sealed by a keeper (an option, `AGENTS_CONTROL_KMS`) |
| `controlplane/web` | The web page's loopback listener |
| `controlplane/hostinstall`, `hosttunnels` | Add a Server over ssh, Detect, the ssh config's hosts, bastion tunnels |
| `controlplane/notices` | Where a need shows (`Routing`), and the relay host's deliveries |
| `controlplane/channels` | Chat apps (Slack) that answer Needs You |
| `controlplane/providers` | Workspace providers, kept requests, Write It for Me |

**Switching a Mac.** Agents Host carries both (`Contents/Helpers/agents-control` and
`agents-control-go`; `scripts/go-control.sh` builds the Go one). It runs the Swift one
unless this Mac's entry in `~/.agents/settings/host.json` says
`"controlImplementation": "go"`; restart the control plane's job after changing it.
`control.log` then begins with `Agents Host: starting the Go agents-control`. Either way
back keeps every member, host and pin.

**On a scratch set-up.** `CONTROL_BIN=$PWD/Go/out/darwin/agents-control
.claude/skills/run-app/scripts/launch.sh --slug …` runs the Go one in place of the Swift
one (build it with `GOOS=darwin Go/scripts/go.sh build -o out/darwin/agents-control
./cmd/agents-control`).
