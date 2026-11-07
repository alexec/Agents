# Wire

The source of every type and method on the wire between the clients, the hosts (`agentsd`)
and the control plane (#1135, step 0 of the move to Go, #1134). It is not a Swift package.

| File | What |
|---|---|
| `daemon.schema.json` | Every type, as JSON Schema draft-07 definitions |
| `daemon.openrpc.json` | The methods a host answers (sent with `h`), its notifications, and the failure codes |
| `control.openrpc.json` | The methods the control plane answers itself, and its notifications |

## What is made from it

`scripts/wire.sh gen` (Go's `cmd/wiregen`, run in a container on the Mac; lease "build") writes:

- **Go:** `Go/wire/types_gen.go` (a type per definition) and `Go/wire/methods_gen.go` (a typed
  `Call…` or `Notify…` value per method, and the `Failure…` codes).
- **TypeScript:** `Web/src/protocol/generated.ts`, for the web page: every type, and the
  methods and notifications tagged `web`.
- **Capabilities (#1748):** `Go/wire/capabilities_gen.go`,
  `Web/src/protocol/capabilities.generated.ts` and AgentsKitCore's
  `Daemon/Capabilities.generated.swift`: a constant per capability, and the capability of each
  method and notification.

`scripts/wire.sh check` writes nothing and fails when one of them is stale; CI's `go` job runs
the same check as a test.

**Swift's types are not made from it** (only its capabilities are). The `Model` types stay written by hand, and `WireSchemaTests`
(in AgentsKit) reads every record in the web fixtures with today's decoder, writes it with
today's encoder, and checks the output against the schema. It also checks that
`DaemonAPI.WebSignatures` and the methods tagged `web` agree.

## Changing a type

1. Change the definition in `daemon.schema.json` (or a method in an `*.openrpc.json`). A new
   definition or method goes where its name sorts, not at the end: `gen` refuses one out of
   name order, so two features that each add one touch different lines (#2020).
2. Run `scripts/wire.sh gen` and commit what it writes.
3. Change the Swift by hand until `WireSchemaTests` passes.

A conflict in a generated file is settled by running `gen` again, never by hand.

## Conventions

- **Methods.** Each method has one param, `params`: the whole of JSON-RPC's params, as
  `DaemonAPI` sends it (an object, or for a few a bare value). A method with
  `"x-notification": true` has no result: the server sends it. The `web` tag marks what the
  web page calls and hears. `control.openrpc.json` has every method the control plane
  answers (#1313), a host's on its channel 0 among them, and what it says to clients and
  hosts. `daemon.openrpc.json` has the host's, as far as the Go host has ported them: each Go
  step adds the methods it ports, with their types, schema first.
- **`x-capability`** on each method and notification names its capability, `<name>/<n>`
  (#1748, `docs/explanation/versions.md`). A method added for a new feature takes the feature's
  name (`chat.branch/1`); the generator refuses a method without one.
- **Numbers.** `integer` is Swift's `Int` (Go `int64`); `number` is `Double` (Go `float64`).
- **The five meaning-types,** written by hand in each language and named by `x-swift-type`
  and `x-go-type` (Go's are in `Go/wire/meaning.go`):

  | Definition | Swift | Go | On the wire |
  |---|---|---|---|
  | `UUID` | `UUID` | `UUID` | upper case |
  | `WireDate` | `Date` | `Date` | seconds since 2001-01-01, a plain `JSONEncoder` |
  | `Base64` | `Data` | `Data` (`[]byte`) | standard base64 with padding |
  | `URLString` | `URL` | `URL` | an absolute URL as text |
  | `JSONValue` | `JSONValue` | `JSONValue` (`json.RawMessage`) | any JSON |

- **`x-ts-type`** is a definition's TypeScript, written out: the meaning-types and the other
  brands (`MachineRef`, `ProviderID`, `ResourceName`).
- **`x-fallback`** says what a forgiving decoder does with what this build does not know:
  a value (`AgentState` reads as `stopped`, `EndedReason` as `unrecognised`), `keep`
  (`TranscriptEntryKind`: kept whole and written back), or `defaults` (`WorkflowSummary`: a
  missing field takes its `default`). The Swift decoders stay hand-written; Go's are generated.
- **A Swift enum with associated values** is `anyOf` of one-key objects, `{"case": {…}}`, and
  an unlabelled value is `_0`. Go makes a struct with a pointer per case.

## Where it came from

The first schema was made from today's Swift, through the `generated.ts` that
`Packages/WebTypes` read from AgentsKitCore's source (`specs/1125-go-agentsd/wire-bootstrap.py`
says how). The plan is `specs/1125-go-agentsd/migration.md`; the evidence is `report.md`.
