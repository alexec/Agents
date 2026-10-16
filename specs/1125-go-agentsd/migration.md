# Moving agentsd and the control plane to Go: a first draft (#1125)

**A draft for Alex to read after the test on 2026-10-17. It is not a decision.** The evidence is in [report.md](report.md). The control-plane spike is #1126.

**The order:** Linux hosts first, then the control plane, then the Mac daemon. Each step lands on `main` by itself and leaves the product working. The Swift window, the Remote and the web page do not change language.

## 0. Before any step: the schema-first wire

The spike's stage 3 proved that one JSON Schema carries every shape on the wire, and that Go, Swift and TypeScript made from it round-trip today's records. Bring it in first, because every later step depends on it.

1. **Check in the schema, made from today's Swift.** `agentsd-go/schema/bootstrap.sh` makes `daemon.schema.json` from `Web/src/protocol/generated.ts` (all 361 definitions). Put it in `Packages/Wire/` (a new folder, not a Swift package).
2. **Add OpenRPC for the methods.** One document, `daemon.openrpc.json`: each method names its params and result from the schema, and each notification too. Make the first one from `DaemonAPI.WebSignatures`, which lists the methods the web page calls, and fill the rest by hand. The control plane's methods (`Control/DaemonAPI+Control.swift`) get a second document.
3. **Write the five meaning-types once, by hand,** in each language: `Date` (seconds since 2001), `UUID` (upper case), `Data` (base64), file `URL`, `JSONValue`. The generators get a type map (`x-swift-type`, `x-go-type`) so the generated code uses them.
4. **Keep the forgiving decoders hand-written** (`TranscriptEntry.unrecognised`, `AgentState` → `stopped`, `WorkflowSummary` defaults). Mark each in the schema as `anyOf` with a fallback, and give `EndedReason` a fallback too, which it lacks today.
5. **CI checks, on every PR that touches the wire:**
   - **Swift:** today's `Model` types stay hand-written. A test (stage 3's `swift-check`, moved into `Packages/AgentsKit/Tests`) encodes each fixture with today's encoder and checks it against the schema. A Swift change that the schema does not allow fails.
   - **TypeScript:** `Web/src/protocol/generated.ts` is made from the schema, not from the Swift source. `Packages/WebTypes` goes. `tsc --strict` checks the web page against it, as today.
   - **Go:** the Go types are generated (`go-jsonschema`) and checked in. The round-trip test runs over the same fixtures.
   - **One rule:** a change to a type changes the schema first; a new `scripts/wire.sh gen` makes the Go and TypeScript, and the Swift check tells you what to change by hand.
6. **Size:** M. Most of it exists in `agentsd-go/schema/`. The OpenRPC document is the new part.

## 1. Linux hosts

**Why first:** the Linux host is the smallest surface, the binary is 9 MB against 78 MB, it builds in 13 s against 336 s with no swift.org toolchain, and Landlock gives Linux a sandbox it does not have today.

### Side by side: the Swift and the Go Linux agentsd

- **The version field.** Each host says its version in `host/hello` (`HostHello.version`). The Go host says `<version>-go` (today `0.1.0-go`). The control plane lists it as it is, and the Hosts pane shows it.
  - Add one field to `HostHello`: `implementation: "swift" | "go"`. The control plane keeps it in the host's record and the Hosts pane shows "Go" beside the version. Nothing else branches on it.
  - The window already copes with a host that lacks a method (`-32601`; stage 5 proved this with 19 missing methods). A Go host that is short of a method shows an empty pane, not an error.
- **The install script.** `HostInstallScript.swift` fetches `/v1/servers/agentsd-linux-<arch>` with its `.sha256` and `VERSION`, puts it in `~/.agents-server/bin/agentsd-<sha>`, points `current` at it and starts it under a systemd user unit. Change only where the binary comes from:
  - The control plane's server folder gets a second set: `agentsd-go-linux-<arch>`, `.sha256`, and `VERSION-go`.
  - `install.sh` takes `--impl go` (or `AGENTS_HOST_IMPL=go`). Without it, it installs the Swift host as today. The control plane's "Add a Server" sheet gets a switch, off by default, until the Go host is the default.
  - The root (`~/.agents-server/root`) and the membership file are the same for both. A host keeps its id when it changes from Swift to Go, because the id is in the root, not in the binary. Changing back is the same script with the other flag.
  - The Go host keeps `agentsd supervise` for a box with no systemd. Under systemd, the unit's `Restart=always` (already in the script) does the job and `supervise` is not used.
- **What must not differ:** the root's files (`agents/`, `projects.json`, workflows, `mcp.json`). The Go host reads and writes today's files. A host that changes language keeps its agents. Port the Swift record tests that check these files as Go tests over the same fixtures.
- **When the Go host is the default:** when it serves every method a server host gets (the table below, less the Mac-only and the control-plane rows), and a week of Alex's own server work has run on it. Then the Swift Linux build leaves `scripts/build-linux-agentsd.sh` and CI, and the Static Linux SDK is no longer needed.

### Also needed, not methods

- **Behaviour the window depends on:** lean `agent/changed`, `agent/entry` only to a client that shows the agent, fan-out frames (#167), turn summaries (`agents/turns`), `files/changed` with watches, and resuming agents after a restart (`session/resume`/`load`). M in total.
- **The toolset installer** on a control-plane host, which nothing does today in Swift or in Go (report, stage 1). M.
- **Elicitations** over ACP (question cards). S–M; `acp-go-sdk` has the types.
- **Tests:** port the daemon's behaviour tests that cover what a server host does. L, and the part that sets the pace.

## 2. The control plane (#1126)

- The Go host already holds both sides of the control plane's exchange (`internal/control`: the HMAC hello, HKDF keys, the SPKI pin, the channel frames). #1126 takes them to a Go `agents-control`.
- **Side by side:** the control plane is one process with one store. Change it in one move per install: the Go `agents-control` reads today's `control/` folder (members, hosts, grants, kept copies) and writes the same files. Agents Host starts whichever binary its bundle carries, so the change is one release, and the next release can go back.
- **The methods:** the 61 in `Control/` (below). Workspaces and providers (#691) and the kept copies are the largest parts.
- **The web page** is served by the control plane, so `Web/dist` moves with it. Nothing in the page changes.

## 3. The Mac daemon

- **Last, because it is the widest:** every method the Linux host serves, plus the Mac-only ones, plus the parts that are fiddly on a Mac: the Keychain sign-in relay (`relay/grant`: read the token with `security … -w`, serve it from a TLS relay on loopback), the code-signature check on `daemon.sock`'s callers (needs cgo for the audit token, or a small Swift helper), launchd, and power (`caffeinate` is enough without cgo).
- **Side by side:** Agents Host's login item starts `agentsd` from the bundle. Ship both binaries in the bundle for one release, with a hidden setting that picks one. Both read the same `~/.agents` root, so a change back keeps everything.
- **Decide then:** whether `sandbox-exec` (deprecated, but it works on macOS 27) is enough, or whether the Mac host needs a Swift helper for the Mac-only APIs.

## The methods not yet ported

Counted on today's tree (`static let` in `DaemonAPI.Method` and its extensions, ACP's own methods left out): **280 methods; the Go host serves 51; 229 are not ported.** The report's earlier count (286 and 232) was made another way, with ACP's own methods in it.

Sizes are rough, for one agent lane: **S** under a day, **M** one to three days, **L** more.

**The daemon's methods (168):**

| Area | Methods | Size | Which |
|---|---|---|---|
| Mac only | 17 | S–M | `credentials/lend`, `credentials/lendSignIn`, `devices/announce`, `devices/forget`, `devices/list`, `devices/startPairing`, `devices/stopPairing`, `mac/open`, `mac/reveal`, `mac/terminal`, `pairing/current`, `person/state`, `relay/register`, `runtimes/install`, `wake/set`, `wake/settings`, `wake/state` |
| The app's tools as RPC (what agents call) | 18 | L | `agents/afterTurn`, `agents/answerSandbox`, `agents/askForm`, `agents/finishTurn`, `agents/listHelpers`, `agents/listSessions`, `agents/manageWorkflows`, `agents/messageAgent`, `agents/moveSelf`, `agents/readSession`, `agents/reportOutcome`, `agents/requestArchiveHelper`, `agents/setOwnLabels`, `agents/setSandbox`, `agents/showFile`, `agents/startHelper`, `agents/stopHelper`, `agents/waitOn` |
| Agents: the rest of a chat's life | 17 | M | `agents/continueInProject`, `agents/delete`, `agents/fork`, `agents/labelVocabulary`, `agents/move`, `agents/recreateWorktree`, `agents/rename`, `agents/resuming`, `agents/sendNow`, `agents/setCeiling`, `agents/setLabels`, `agents/setOption`, `agents/stopBackground`, `agents/suggestPrompts`, `agents/touchedPaths`, `agents/unarchive`, `agents/unqueue` |
| Questions and approvals | 4 | M | `approvals/answer`, `approvals/read`, `attention/pending`, `elicitations/answer` |
| Workflows in full | 6 | M | `workflows/approve`, `workflows/archive`, `workflows/delete`, `workflows/deny`, `workflows/mcpTrigger/clearMissed`, `workflows/settings` |
| Events | 6 | M | `events/cancel`, `events/cancelWait`, `events/list`, `events/raise`, `events/server`, `events/wait` |
| Leases and resources | 8 | S | `leases/end`, `leases/lease`, `leases/list`, `leases/release`, `leases/removeWaiter`, `leases/snapshot`, `resources/declare`, `resources/remove` |
| Pins | 12 | S | `pins/arrange`, `pins/arrangeSessions`, `pins/arrangeWorkflows`, `pins/list`, `pins/pin`, `pins/pinSession`, `pins/pinWorkflow`, `pins/read`, `pins/unpin`, `pins/unpinSession`, `pins/unpinWorkflow`, `pins/write` |
| Worktrees and changes | 7 | M | `changes/file`, `changes/list`, `worktrees/all`, `worktrees/check`, `worktrees/list`, `worktrees/remove`, `worktrees/removeBuildOutput` |
| Projects: the rest | 13 | M | `projects/archive`, `projects/chatState`, `projects/clone`, `projects/clones`, `projects/delete`, `projects/find`, `projects/keepGuardedChange`, `projects/readGuardedChange`, `projects/setDiskSpace`, `projects/setHelperLimits`, `projects/setPinned`, `projects/unarchive`, `projects/undoGuardedChange` |
| MCP servers, catalog, marketplaces, skills, plugins | 18 | L | `catalog/preview`, `catalog/search`, `marketplaces/add`, `marketplaces/list`, `marketplaces/remove`, `mcp/add`, `mcp/approve`, `mcp/forgetViews`, `mcp/health/check`, `mcp/list`, `mcp/preview`, `mcp/remove`, `mcp/verify`, `plugins/approve`, `plugins/list`, `skills/add`, `skills/list`, `skills/remove` |
| Runtimes: accounts, providers, assessments | 9 | M | `runtimes/accounts`, `runtimes/allowances`, `runtimes/assess`, `runtimes/assessment`, `runtimes/authenticate`, `runtimes/disableProvider`, `runtimes/logout`, `runtimes/markAvailable`, `runtimes/setProvider` |
| Cost, usage, time, milestones | 5 | M | `cost/setLimits`, `cost/state`, `milestones/state`, `time/history`, `usage/history` |
| App views | 6 | M | `views/call`, `views/context`, `views/log`, `views/read`, `views/show`, `views/toolCall` |
| Runtime sessions (adopt, list, delete) | 3 | S | `sessions/adopt`, `sessions/delete`, `sessions/list` |
| Settings the window reads (personas, remembered options, preferences) | 5 | S | `modes/remembered`, `options/remembered`, `personas/list`, `preferences/get`, `preferences/set` |
| Files in and out (artifact, drop box, mailbox, shared) | 4 | S | `artifact/write`, `dropbox/put`, `mailbox/carry`, `personal/shared` |
| Host plumbing (status, catch-up, states) | 10 | S | `client/catchUp`, `clientPermissions/state`, `connection/bindDevice`, `daemon/quit`, `daemon/status`, `disk/state`, `retention/state`, `sandbox/state`, `store/notes`, `surface/identify` |

**The control plane's methods (61, for #1126):** `agents/providerDraft` `agents/workspaces` `attention/need` `channels/get` `channels/set` `clients/announce` `clients/connections` `clients/forget` `clients/forgetSelf` `clients/list` `clients/setGrant` `clients/startPairing` `clients/stopPairing` `control/ping` `control/setProjectDetection` `control/status` `host/hello` `host/providerDraft` `host/status` `host/workspaces` `hosts/announce` `hosts/checkAgain` `hosts/deleteWorkspace` `hosts/detect` `hosts/dropKept` `hosts/install` `hosts/keep` `hosts/lastHeard` `hosts/lendSignIn` `hosts/link` `hosts/list` `hosts/listKept` `hosts/remove` `hosts/retryKept` `hosts/setRelay` `hosts/setWorkspaceOptions` `hosts/sshHosts` `hosts/start` `hosts/startEnroll` `hosts/stop` `hosts/unlink` `hosts/update` `projects/detect` `projects/detected` `providers/add` `providers/create` `providers/draftAnswer` `providers/draftCancel` `providers/draftStart` `providers/list` `providers/options` `providers/refresh` `providers/remove` `providers/runtimes` `providers/update` `relay/deliver` `relay/devices` `relay/grant` `relay/switch` `tunnel/open` `workspaces/forAgent`

## What Alex decides, after the test

- Whether to go on at all, and in this order.
- Whether `implementation` belongs in `HostHello`, or whether the version string (`…-go`) is enough.
- When the Go Linux host becomes the default, and when the Swift Linux build goes.
- Whether the Swift `Model` types stay hand-written and checked (this draft) or are generated from the schema too.
