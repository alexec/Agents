# Data model: Team tier

All keys are under `<prefix>/v1/`, as in `specs/058-control-plane/contracts/store.md`. Every record keeps `rev` and the tombstone fields (rules 10 and 11), and keeps the fields it does not know (`Extra`). Plain JSON files only.

## User (`people/<id>.json`, extended)

Today the record is `{id, name}`. The key stays `people/`, so no record moves (FR-003).

| Field | Type | Notes |
|---|---|---|
| `id` | string | lower-case UUID, as today |
| `name` | string | |
| `kind` | `"person"` \| `"bot"` | absent = `person` |
| `role` | `"admin"` \| `"member"` | absent = `admin` (the existing person, FR-003) |
| `signIns` | `[SignIn]` | persons only. The migration adds `{provider: "local", account: <control-key id>}` |
| `group` | string? | bots only, a group id |
| `caps` | `{dailyUSD?: number}` | bots only |
| `removed`, `removedAt` | tombstone | a removed person's sign-ins are refused until a new invite |

**SignIn**: `{provider: "local"|"google"|"apple"|"github"|<id>, account: string, email?: string, login?: string, added: Stamp}`. `account` is `sub` for OIDC and the numeric id for GitHub. `(provider, account)` is unique across users. The store checks this with `signins/<provider>/<sha256(account)>.json` → `{user}`, written with `absent`.

**States**: `member ⇄ admin` (refused if it leaves no admin, checked with `matching`, rule 3). `active → removed`.

## Sign-in provider (`control.json` → `signIn`)

| Field | Type | Notes |
|---|---|---|
| `google` | `{on, allowedDomains: [string]}` | |
| `apple` | `{on}` | |
| `github` | `{on, allowedOrgs: [string]}` | |
| `others` | `[{id, kind: "oidc"\|"oauth-github", issuer?, clientID}]` | T9, configuration only (FR-013) |

The client ids of the built-in providers are compiled into the apps and the control plane. They are not stored.

## Invite (`invites/<id>.json`)

`{id, email?, role, by: user, created, expires (7 d), usedBy?: user, usedAt?}`. It is spent by a create-only `invites/<id>.used`, as codes are spent today.

## Client (`clients/<uuid>.json`, extended)

- `owner` is now required. The migration fills it with the local owner.
- `expires`: Stamp, T4.
- `signIn`: the `(provider, account)` that paired it, so renewal can check it.

## Machine (`hosts/<id>.json`, extended)

- `owner` (a user id) is now required. The migration fills it.
- `labels`: `[string]`, set by the user. The control plane adds `os:`, `provider:`, the user's name and the id when it matches labels. It does not store them.
- `expires`: Stamp, T4.
- `joinedBy`: `"approval"` | `"code"` | `"token"`, with `approvedBy?` (a user).
- `Workspace` stays as #691 wrote it.

## Join request (`joins/<id>.json`)

`{id, code (6 chars), name, platform, publicKey, person?: user, bot?: user, from: address, created, expires (10 min), result?: "approved"|"denied"|"expired", by?: user}`.

## Join token (`codes/<id>.json`, the existing code record)

`purpose: {join: {user, provider, workspace}}`, one use, 1 hour. It is spent by `codes/<id>.spent` as today.

## Group (`groups/<id>.json`)

`{id, name, members: "everyone" | [user]}`. A workspace provider's record (`providers/…`) gains `group`. With no group, it is the admin's own, which is the migration for today's providers.

## User settings (`users/<id>/settings.json`)

`{mcpServers: [...], agentConfig: {...}, runtimes: {...}, costLimits: {...}, resources: {...}}`. Each part keeps the shape it has today in `~/.agents`. The control plane does not read inside a part. It only keeps it and sends it.

## User secret (`users/<id>/secrets/<name>.json`)

`{name, keyVersion, dataKeyWrapped: base64, nonce: base64, ciphertext: base64, updated}`. It is never readable without `kms.Keeper` (FR-025, SC-007).

## Channel link (`links/<channel>/<sha256(identity)>.json`)

`{channel, identity, user, approvedBy, approvedAt}`.

## Run claim (`runs/<workflow-id>/<trigger-id>.json`)

`{machine, claimedAt}`. It is written with `absent`, and the first writer runs. It is swept after 7 days.

## Audit entry (`events/<day>/<ulid>.json`, extended)

The existing event gains `actor: {user, client?, event?: {kind, id}}`. The retention is `control.json` → `auditDays` (default 90).

## Spend (`spend/<user>/<day>.json`)

`{usd, byMachine: {<host>: usd}}`. The control plane adds machines' reports here, for bots and their groups (FR-033).
