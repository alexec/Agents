# Research: Capabilities decide, versions inform (#1748)

Each item is a decision for this lane. Those that change what Alex sees or the wire are also on
#1748, with `Decided:` and the `decided` label (Alex can overrule).

## R1. The names of the capabilities

- **Decision:** `<name>/<n>`, lower case, dots for parts, hyphens in words. Each method that was
  in `v0.5.0` takes `<namespace>/1` (`agents/1`, `hosts/1`). Each method added after `v0.5.0`
  takes the name of its feature: `chat.branch/1` (`agents/branchFrom`), `agents.edit-queued/1`,
  `agents.find/1`, `agents.said/1`, `connections/1`, `connectors.setup/1`, `files.complete/1`,
  `files.diagnostics/1`, `mcp.made-by-agents/1`, `simulators/1`.
- **Rationale:** about 80 names, not one per method (350): the list is small to send and to read.
  The features that came after 0.5 are what an older host does not have, so only they need a
  name of their own.
- **Alternatives:** one capability per method (lists of 350 names, and no feature name for
  people); one per namespace for all (an older host with `agents/1` would seem to have `agents/find`).

## R2. Where the generated code goes

- **Decision:** new files, not new parts of the old ones: `Go/wire/capabilities_gen.go`,
  `Web/src/protocol/capabilities.generated.ts`,
  `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/Capabilities.generated.swift`.
- **Rationale:** the held audit lane (PR #1752) changes `methods_gen.go` and `generated.ts`.
  New files keep the generated conflicts to the ones `gen` settles, and give Swift its first
  generated file without touching the hand-written `Model` types.

## R3. How the `x-capability` lines go into the documents

- **Decision:** one line, `"x-capability": "<name>/<n>",`, after each method's `"name"` line,
  put in by a one-time script that keeps the files' format. The script is not kept.
- **Rationale:** a reformat with `jq` rewrites every line and conflicts with every open wire PR.

## R4. Where each peer sends its list

- **Decision:**
  - a host: `capabilities` in `HostHello`, on each connect (not in `HostAnnounce`: a
    `host/hello` follows each enrolment);
  - a client: `capabilities` in `ControlAuth`, the auth line of every connection;
  - the control plane: `capabilities` and `required` (`{host, client}`) in `ControlStatus`, and
    each host's list as `capabilities` on `ControlHost`.
- **Rationale:** `clients/announce` is sent once, when a device pairs, and a client's list
  changes with each update. `ControlAuth` is on every connection of every client kind, the web
  page too. `ControlHost` is what each client already keeps for each host, and
  `control/hostChanged` already says when it changes, so no `host/capabilitiesChanged` is needed.
- **Alternatives:** a new `clients/hello` call (one more round trip on each connect); a
  `host/capabilitiesChanged` notification (it says again what `control/hostChanged` says).

## R5. A peer that sends no list

- **Decision:** a build from before this feature. Nothing is gated for it and nothing is refused;
  the clients act as today, with -32601 as the fall-back. Its row says the version only.
- **Rationale:** the Remote on Alex's devices and the hosts on servers update later. Refusing
  them when the control plane updates would break them on a minor that removes nothing.

## R6. Which methods a peer "has"

- **Decision:** a capability is in a Go server's list when it registers each method of its own
  document that names it (`d.handlers` for `agentsd`; the control plane's dispatch for
  `agents-control`). Notifications do not take part: the server's document says what it sends.
  Capabilities with no method are declared by hand, in each document's top-level
  `x-declared-capabilities` (`{name, by, description}`, `by` is host, client or control), so
  the generator makes their constants too: `host.wire/1` (daemon) and `client.wire/1` (control).
- **Rationale:** FR-007; a host that ports only part of a feature does not claim it.

## R7. The required sets

- **Decision:** `host.wire/1` for hosts and `client.wire/1` for clients, in
  `Go/internal/controlplane/capabilities.go`. Each says the peer speaks today's wire with a list.
- **Rationale:** rule 6: the required set is the minimum the control plane routes, and it moves
  only when a capability number is removed. Today every peer with a list can be routed, so the
  set is the two declared names; the day a release removes `files/1`, `files/2` joins it.
- **Alternatives:** every method capability a host serves today (a host that ports a little less
  on Linux, such as `devices/1`, would show "Needs an update" for a feature it never had).

## R8. `-32008` for a client

- **Decision:** the exchange still succeeds. Each call except `control/status` is answered `-32008` with `data: {missing: [...], update: "<version>"}`.
  The clients show one "Update this app" notice for it.
- **Rationale:** the exchange's refusals are reasons for a bad identity, not for an old build,
  and a refused socket gives the client nothing to show.

## R9. The version string

- **Decision:** one script, `scripts/version.sh`, prints the version for HEAD in the form of
  rule 8. Every build script uses it, and ship.sh sets `MARKETING_VERSION` from
  `version.sh --marketing` (`X.Y.Z` only: Apple takes digits and dots). `release-store.sh` and
  `release-host.sh` keep setting it from the tag. The web page stamps no version: the control
  plane serves it, so its version is the control plane's, and Web/dist's MANIFEST stays the
  same for the same inputs.
- **Rationale:** today `git describe` gives `0.6.0-12-gabc`, which SemVer sorts below `0.6.0`.
