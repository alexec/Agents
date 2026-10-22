# Contract: org routes on the wire

The types go in `Packages/Wire/daemon.schema.json`, the methods in `Packages/Wire/control.openrpc.json` and `daemon.openrpc.json`. `scripts/wire.sh gen` makes the Go and TypeScript, and `WireSchemaTests` says what to write in Swift (#1135).

## Client → control plane

| Method | Who | Params | Result | Notes |
|---|---|---|---|---|
| `orgRoutes/mine` | any person | – | `[{id, name, kind, runtimes, defaultFor}]` | the routes the caller may use; no settings, no fingerprint |
| `orgRoutes/list` | admin | – | `[OrgRoute]` with `rev`, and per route `machines` (count that hold it) | no value |
| `orgRoutes/set` | admin | `{route: OrgRoute, secrets?: {<field>: string}, rev?}` | `OrgRoute` | add or change; `secrets` write only; conditional on `rev`; checks the kind against each runtime; raises `version`; audits; delivers |
| `orgRoutes/replaceKey` | admin | `{id, secrets: {<field>: string}, rev}` | `OrgRoute` | the same as `set` with secrets only |
| `orgRoutes/check` | admin | `{id}` | `{ok: bool, words: string}` | one small request from the control plane where it can (keys, base URLs); "Check on a machine" otherwise |
| `orgRoutes/remove` | admin | `{id, rev}` | – | deletes both records; delivers |

**Notification to clients**: `control/orgRoutesChanged` (no body) to every person's clients, so a client reads `runtimes/accountProfiles` again.

## Control plane → machine (channel 0)

| Message | When | Body |
|---|---|---|
| `host/orgRoutes` | on connect, and within 5 s of a change that alters this machine's delivery, to machines that say `host.orgRoutes.1` | `OrgRouteDelivery` |
| `host/policy` (T5) | as T5 | carries `runtimes.<id>.reach` and `notices.antigravityTerms` |

## Machine → control plane

| Message | Body | Notes |
|---|---|---|
| capability `host.orgRoutes.1` | in `host/hello` | |
| `host/orgRoutesApplied` | `{routes: [{id, version}]}` | after it keeps a delivery; the Console shows which machines hold each route |
| `host/orgRoutesAgain` | – | a sealed file did not open; send the delivery again |
| `usage/rollup` (extended) | rows with `route` | |

## Machine → clients (daemon API)

- `runtimes/accountProfiles` (#840) lists org accounts with `source: organisation` and T5's `setBy`.
- `runtimes/setDefaultAccount` `{runtimeID, accountID}`: the person's **Reaches the Model By**; refused with `policyRefused` when the policy refuses it.
- `StartRequest.accountID` (#840) takes an org account's id (`org:<route id>`).
- The runtime's sign-in methods carry no `signInNotice` under `notices.antigravityTerms: accepted`, and a `policyNote` with the line of spec US6.

## Errors

| Code | When | Client words |
|---|---|---|
| `policyRefused` (rule `runtimes.<id>.reach`) | a sign-in account under "the org path only", or the reverse | **Set by your organisation.** "Your organisation requires Claude to use Acme Bedrock." |
| `policyRefused` (rule `notices.antigravityTerms`) | Antigravity under `refuse` | **Set by your organisation.** "Your organisation does not allow Antigravity, because of Google's terms on third-party tools." |
| `orgRouteMissing` | the org path is required and no route reached this machine | "Your organisation's way to this model has not reached this machine. Connect to the network." |
| `orgRouteRemoved` | a session's route was removed or the person is no longer allowed | "Your organisation removed Acme Bedrock." + **Continue in New** |
| `orgRouteExpired` (Q1 A) | a short-lived token ended offline | "Your organisation's Bedrock access ended while this machine is offline. Connect to the network." |

## The model relay (loopback, not the daemon API)

- `https://127.0.0.1:<port>/<route id>/…`: the rest of the path goes to the route's address as it is.
- The stand-in comes in the header the runtime uses (`x-api-key`, `Authorization`, `api-key`, `x-goog-api-key`). A wrong one: 401, nothing sent on.
- The answer is streamed back as it is, except that the relay reads the usage fields of research R5 on the way.
