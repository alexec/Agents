# Data model: Enterprise T6, org keys and model gateways

All control-plane keys are under `<prefix>/v1/`, as in `specs/058-control-plane/contracts/store.md`. Every record keeps `rev`, and keeps the fields it does not know. Plain JSON files only.

## OrgRoute (`v1/org/routes/<id>.json`)

No secret is in this record.

| Field | Type | Notes |
|---|---|---|
| `id` | string | `[a-z0-9-]{1,40}`, made from the name at add, never changed |
| `name` | string | what members see ("Acme Bedrock"), 1–60 characters |
| `kind` | `"key"` \| `"bedrock"` \| `"vertex"` \| `"azure"` \| `"baseURL"` | |
| `vendor` | `"anthropic"` \| `"openai"` \| `"gemini"` \| `"xai"`? | for `key`, and the API shape of `baseURL` and `azure` |
| `runtimes` | `[runtime id]` | only runtimes whose row in the spec's table allows the kind |
| `settings` | object | not secret. `bedrock`: `region`. `vertex`: `project`, `location`. `azure`: `resource` or `address`, `apiVersion?`. `baseURL`: `address`, `header?` (the header the key goes in) |
| `models` | `{<runtime model id>: <gateway model id>}`? | the model map; absent = the runtime's ids as they are |
| `groups` | `[group id]` | empty = everyone (spec D6) |
| `defaultFor` | `[runtime id]` | the route is the default account of these runtimes |
| `secretFields` | `[string]` | the names of the secret fields that are set (`apiKey`, `awsRoleArn`+`externalId`, `serviceAccount`, `entraClientSecret`, …), never the values |
| `fingerprint` | `{<field>: string}` | the first 8 hex of SHA-256 of each value (spec D14) |
| `version` | integer | +1 on each change, also a key replaced |
| `created`, `changed` | `{by: Actor, at: Stamp}` | T3's actor |

**Bounds**: up to 50 routes; up to 10 secret fields per route, each under 16 KiB (the #1760 bound).

## OrgRouteSecret (`v1/org/routes/<id>.secret.json`)

The #1760 envelope (`kms.Sealed`), sealed with `kms.SealFor` bound to its store key, over `{<field>: <value>}`. Written in the same change as the route record, before it. Removed with the route.

## OrgRouteDelivery (wire, `host/orgRoutes`)

`{routes: [DeliveredRoute], at: Stamp}`. An empty list removes every route.

**DeliveredRoute**: the OrgRoute without `groups`, `fingerprint`, `created`, `changed`, plus `sealed: {<field>: SealedEnvelope}`. Each envelope is HPKE to the machine's key (research R4). Under Q1 answer A, a cloud-credential route carries `token` fields (`awsSession`, `googleToken`, `entraToken`) with `expires`, never the long-lived ones.

## On the machine

| File | What |
|---|---|
| `<root>/org-routes/<id>.json` (0600) | the DeliveredRoute as received, envelopes still sealed |
| `<root>/runtimes/org/<runtime>/<route id>/` | the account folder for runtimes that need one (Codex `CODEX_HOME`, OpenCode config, Claude `CLAUDE_CONFIG_DIR` with the person's settings linked in, #840). No secret in it |
| `<root>/runtimes/model-relay-ca.pem` | the relay's CA certificate (public) |

## AccountProfile (#840, extended)

| Field | Change |
|---|---|
| `id` | an org account's id is `org:<route id>`, the same on every machine, so `Agent.accountID` and the allowance key `<runtime>:account:org:<route id>` name it |
| `reach` | gains `{orgKey: {route}}` and `{gateway: {route, kind}}` beside `{signIn: {folder}}` |
| `source` | new, `"person"` (absent) or `"organisation"` |
| `setBy` | T5's mark, when the policy refuses this account |
| `signedIn` | always true for an org account |

## Runtime default (user setting)

The runtimes part of the user settings (#1760) gains `defaultAccount: {<runtime id>: <account id> | "default">`. Absent = the org route that is `defaultFor` it, else the runtime's own sign-in.

## Policy (T5, extended)

| Field | Type | Notes |
|---|---|---|
| `runtimes.<id>.reach` | `["signIn" \| "orgKey" \| "gateway"]`? | absent = every way |
| `notices.antigravityTerms` | `"show"` \| `"accepted"` \| `"refuse"`? | absent = `show` |

`requires` gains `host.orgRoutes.1` when either is set.

## Usage

| Record | Change |
|---|---|
| A turn's usage (machine) | `accountID` (#840), `route?`, `relayTokens?: {input, output, cacheRead, cacheWrite}` |
| `UsageRollupRow` | `route?`; its `limitTokens` (T5) uses `relayTokens` when present |
| Control plane roll-up | by route, person and UTC day, for Console ▸ Reports |

## States of a route on a machine

absent → delivered (file kept, account listed) → replaced (new version, old file overwritten) → removed (file deleted, sessions stopped, account gone). A file that does not open → deleted → asked again.
