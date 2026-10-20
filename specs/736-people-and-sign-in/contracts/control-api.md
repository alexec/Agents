# Contract: control-plane methods for the team tier

These change `Packages/Wire/control.openrpc.json` first, then `scripts/wire.sh gen` (#1135).

**Who may call:**

- **any**: any signed-in client, for itself;
- **admin**: an admin's client;
- **enrol**: an enrolment connection with no key yet.

Every method that names a machine is refused with `notFound` unless the caller's user owns it (FR-018). Admin methods that list machines return the name, user and state only.

## Sign-in and people

| Method | Who | Shape |
|---|---|---|
| `signIn/providers` | pairing | → `{google?, apple?, github?, others}`, with what is on, for the client's sign-in sheet |
| `signIn/oidc` | pairing | `{provider, idToken, invite?}` → `{client, person, controlKey}`. Checks R2. A person not yet known needs `invite`, or an allowed domain |
| `signIn/github` | pairing | `{token, invite?}` → `{client, person}` or `{waitingForApproval: requestID}` (R3) |
| `signIn/addToMe` | any | `{provider, idToken \| token}` → `{person}`: adds a sign-in to the caller's person (FR-005) |
| `people/list` | any | admin: every user. Member: themselves → `[{id, kind, name, role, signIns, clients, machines: [{id, name, state}]}]` |
| `people/invite` | admin | `{email?, role}` → `{invite, code, expires}` |
| `people/setRole` | admin | `{user, role}` → `{}`. Refuses to leave no admin |
| `people/removePreview` | admin | `{user}` → `{startedMachines: [{host, unpushed: [{branch, worktree?, ahead}]}], registeredMachines}` |
| `people/remove` | admin | `{user}` → `{}` (FR-029) |
| `signIn/configure` | admin | `{google?, apple?, github?}` → the same |

## Machines

| Method | Who | Shape |
|---|---|---|
| `hosts/requestJoin` | enrol | `{name, platform, publicKey, person?}` → `{request, code, expires}`. Then `control/joinDecided {result, host?}` on the same connection |
| `hosts/approveJoin` | any (the named person) or admin (no person, or a bot) | `{request, as?: botUser}` → `{host}` |
| `hosts/denyJoin` | the same | `{request}` → `{}` |
| `hosts/startEnroll` | any | as today. The code's machine belongs to the caller |
| `hosts/setLabels` | owner | `{host, labels}` → `{}` |
| `hosts/list` | any | the caller's own machines. Each item gains `labels`, `owner` and `workspace?` |

## Groups, providers and bots

| Method | Who | Shape |
|---|---|---|
| `groups/list`, `groups/set`, `groups/remove` | admin (list: any, own groups) | `{id?, name, members}` |
| `providers/setGroup` | admin | `{provider, group}` → `{}` |
| `bots/make` | admin | `{name, group, caps?}` → `{user}` |
| `bots/setCaps` | admin | `{user, caps}` → `{}` |
| `bots/stopRun` | admin | `{host, agent}` → `{}`: the one way a client acts on a bot's machine (FR-031) |

## User scope

| Method | Who | Shape |
|---|---|---|
| `user/settings` | any (admin for a bot: `as`) | → `UserSettings` |
| `user/setSettings` | the same | `{part, value}` → `{}` |
| `user/setSecret` | the same | `{name, value}` → `{}`. The value is never sent back |
| `user/removeSecret` | the same | `{name}` → `{}` |
| `user/secretNames` | the same | → `[{name, updated, machines: [host]}]` |

## Channels and audit

| Method | Who | Shape |
|---|---|---|
| `links/approve`, `links/deny` | the person named | `{request}` → `{}` |
| `links/list`, `links/remove` | any (own), admin (all) | |
| `audit/list` | any (own), admin (all) | `{since?, until?, user?}` → `[AuditEntry]` |
| `audit/export` | admin | the same → JSON lines, streamed |
| `control/setAuditDays` | admin | `{days}` → `{}` |

## Key lifetimes

| Method | Who | Shape |
|---|---|---|
| `control/renew` (notification, then the reply) | any, machine | `{expires, signature}` → `{expires}` |
| `control/rotate` | admin | `{}` → `{}`. Then `control/newKey {key, signatureByOld}` to every connection |

## Notifications

| Notification | To | Shape |
|---|---|---|
| `control/joinRequested` | the named person's clients, or admins' clients | `{request, name, platform, code, expires, for: user}` |
| `control/linkRequested` | the person, or admins | `{request, channel, identity}` |
| `control/peopleChanged` | admins, and the person changed | `{user?, removed?}` |
| `control/cutOff` | a client of a removed person | then close 4403 `removed` |

## Channel 0, machine ↔ control plane

| Message | Direction | Shape |
|---|---|---|
| `host/hello` reply | → machine | gains `{user, userKind, labels}` |
| `user/settings` | → machine | `{settings, secrets: [{name, value}]}` at join and on change. Sent only on this user's machines' links |
| `user/capReached` | → bot machine | `{until}` |
| `workflows/claimRun` | machine → | `{workflow, trigger}` → `{won: Bool}` |
| `cost/report` | machine → | `{day, usd}`, folded into idle reports |
| envelope `actor` | → machine | `{user, client?, event?}` on every passed call (T3) |

## Failures

| Code | Name | Meaning |
|---|---|---|
| `-32071` | `signInUnavailable` | a provider cannot be reached, with `{provider, reason}` |
| `-32072` | `needsInvite` | a sign-in for a person not known, with no invite or allowed domain |
| `-32073` | `botMachine` | a client action on a bot's machine (FR-031) |
| `-32074` | `updateToJoinTeam` | an older build on a control plane with more than one person (R14) |

A request for another user's machine is refused with the existing `notFound`, never with a code of its own (FR-018). These numbers were free on 2026-10-20; the lane that adds them checks `Packages/Wire` again.
