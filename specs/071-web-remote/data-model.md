# Data Model: The Web Remote, First Version

What is new or changed. Everything else is 058's
([data-model.md](../058-control-plane/data-model.md)) and is unchanged.

## ClientRecord (changed)

`Packages/AgentsKit/Sources/AgentsKitCore/Control/Grant.swift`.

| Field | Change |
|---|---|
| `kind` | `Kind` gains `browser`, raw value `"browser"`. A record of an older control plane decodes as before. A browser record read by an older build decodes as `unknown`, which is the existing fallback. |
| `name` | For `browser`: `"<product> on <Mac name>"`, set by the control plane at `clients/announce` (research R5). |

Rules:
- `kind: browser` is accepted at `clients/announce` only on a session that came through the
  loopback listener. A browser announced through 8791 gets `invalidParams`. Any other kind
  announced through the loopback listener gets the same.
- A browser is promoted, demoted and forgotten like any other client (FR-013). The
  last-operator rule is unchanged.
- `lastSeen` is written as for any client: at most hourly.

## Browser key (new, in the browser only)

IndexedDB database `agents` (version 1), object store `key`, one record under the key `self`.

| Field | Type | Notes |
|---|---|---|
| `privateKey` | `CryptoKey` | ECDH P-256, `extractable: false`, usages `["deriveBits"]`. |
| `publicKey` | `CryptoKey` | Exportable as raw (X9.63, 65 B). It is sent at `clients/announce`. |
| `client` | string (UUID) | Identity `c:<client>`. Made by the browser with `crypto.randomUUID()` at pairing. |
| `control` | string (base64url X9.63) | The control plane's key from the code, checked against each `hello`. |
| `grant` | `"operator"` \| `"device"` | As last told by `ok`. Shown at the foot of the projects column. |
| `paired` | string (ISO date) | |

States:
- **None → pairing.** The page opens with no record, or with a record that fails the
  `extractable === false` check, which it deletes.
- **Pairing → paired.** A code is pasted and the `p:` exchange succeeds. Then the key is made,
  stored and read back, and `clients/announce` is answered.
- **Paired → paired.** Each connection succeeds as `c:<client>`.
- **Paired → none.** Any of:
  - close code 4403;
  - `refused: forgotten` or `refused: unknown`;
  - **Forget This Browser** answered;
  - a `BroadcastChannel` `forgotten` from another tab.

  The record and the database are deleted.
- **Paired → wrong control plane.** `hello.control ≠ control`. Nothing is sent, the record is
  kept, and the page says so. A control plane rebuilt on the same port with a new key is the
  likely cause, and only forgetting locally (a button on that screen) clears it.

## Loopback listener settings (new)

| Setting | Where | Default |
|---|---|---|
| `--web DIR` | `agents-control` | none. Agents Host passes `<bundle>/Contents/Resources/web` |
| `--web-port N`, `AGENTS_CONTROL_WEB_PORT` | `agents-control` | 8792 with `--home`; otherwise none, so off |
| `--no-web` | `agents-control` | absent |
| `serveWebRemote` | Agents Host defaults (`UserDefaults`, scoped by root as other Agents Host keys are) | `true` |

In memory, per copy:
- `webOrigin` is `http://localhost:<port>`.
- `webFiles` is `[path: (bytes, contentType, sha256)]`, loaded from `MANIFEST`.
- Each `ClientSession` gains `via: .tls | .loopback`, used for the `kind` rule above and for
  the close code.

## WebSignatures (new)

`Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI+Web.swift`.

```swift
public enum WebSignatures {
    public struct Row { let method: String; let params: Any.Type; let result: Any.Type; let kind: Kind }
    public enum Kind { case hostRequest, controlRequest, hostNotification, controlNotification }
    public static let rows: [Row] = [ /* one per method the web app uses */ ]
}
```

Rules, checked by `WebSignaturesTests`:
- every `hostRequest` method is in `ConnectionRole.deviceMethods` (FR-016);
- every `controlRequest` is one the control plane answers for the `device` grant
  (`control/status`, `hosts/list`, `presence/report`, `clients/forgetSelf`, `daemon/ping`);
- no method appears twice;
- `Void`-like params or results use `DaemonAPI.Empty`.

The first rows come from what the Remote calls today (the Remote's method list). The reads
are:

```text
projects/list  agents/list  agents/transcript  agents/turns  agents/options  runtimes/list
runtimes/accounts  options/remembered  modes/remembered  permissions/pending  elicitations/pending
attention/pending  worktrees/list  workflows/list  files/list  files/read  changes/list
changes/file  agents/labelVocabulary  costState  eventsList  leasesSnapshot
```

The writes are:

```text
agents/start  agents/prompt  agents/sendNow  agents/unqueue  agents/stop  agents/stopBackground
agents/park  agents/unpark  agents/archive  agents/unarchive  agents/setLabels  agents/setOption
permissions/answer  elicitations/answer  agents/answerSandbox  workflows/run  files/watch
files/unwatch  artifact/write  files/mention  presence/report  surface/identify
```

The control plane's own:

```text
control/status  hosts/list  clients/forgetSelf
```

The notifications:

```text
agent/changed  agent/entry  agent/removed  agent/permission  agent/elicitation  project/changed
attention/changed  files/changed  control/hostChanged
```

The exact constant names are taken from `DaemonAPI.Method` when the table is written (T013).

## Generated protocol types (new, generated)

`Web/src/protocol/generated.ts`. Its shape is fixed in
[contracts/generated-types.md](contracts/generated-types.md). It is never edited by hand.

## Web fixtures (new)

`Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/web/<rule>/<case>.json`:

```jsonc
{
  "name": "parked sorts by parkedAt, newest first",
  "now": "2026-09-30T12:00:00Z",          // where the rule reads the time
  "input": { /* Swift-encoded values: agents, notifications, … */ },
  "expected": { /* plain JSON: groups with ordered ids, words, counts, … */ }
}
```

Rule folders: `groups`, `status`, `turns`, `background`, `labels` and `reducer` (research
R7). Each has a `README.md` naming the Swift function it pins.

## Web/dist/MANIFEST (new, generated)

```text
agents-web 1
node v<version>
esbuild <version>
src <sha256> Web/src/…            # sorted by path
out <sha256> Web/dist/app.js      # sorted by path
```

It is written by `Web/build.mjs` and read by `WebDistManifestTests` and by the control plane at
start (research R8).

## Web app state (in memory, in the page)

The port of `AgentsModel`, one per tab:
- `hosts`: `[HostID: {name, state}]`, from `hosts/list` and `control/hostChanged`.
- `projects`: by host.
- `agents`: by id. Groups, order and counts are computed by the ported rules.
- `transcripts`: per open session.
  - the loaded turns (`agents/turns`) and entries (`agents/transcript` from `openStart`);
  - `heardSincePage`, to merge entries that arrive while a page loads (as
    AgentsModel.swift 680–686).
- `pending`: permission requests and elicitations by agent.
- `draft`: per session, the prompt's text and attachments. It is kept in memory only, never in
  storage, and survives disconnection (US7).
- `link`: `connecting`, `open`, `down(since)` or `forgotten`.

On every `open`, the page refreshes everything, as the Mac window's `refreshEverything` does:
agents, then projects, then the rest in parallel, then the open transcript. There are no
cursors, because the wire has none.
