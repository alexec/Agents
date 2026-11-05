---
description: The client seals an org route's secrets and a person's own secrets to each machine's key; the control plane keeps and sends only ciphertext it cannot open (#3397).
---

# The client seals; the control plane never opens

Issue #3397, a child of epic #3401 ("The hosted control plane holds nothing it could
misuse"). Principle 6 of `docs/explanation/direction.md`.

## What changes

Today the control plane seals an org route's secrets and a person's own secrets with its
keeper (Cloud KMS, Vault or the local key file). To send them to a machine, it opens them
and seals them again to the machine's key (org routes), or sends them in plain on the
machine's channel 0 (a person's secrets). Whoever runs the control plane with its keeper
can read every customer's AI keys.

After this change, a **client** (the web page, the Mac window, the Remote) seals each value
with HPKE straight to each machine that may use it. The control plane keeps and forwards
only that ciphertext. It never has a plain value, in its store or in its memory, and it
does not use its keeper for these secrets.

## Decisions (Alex, 2026-11-04, form on #3397)

1. **Client keys.** Each value is sealed to each machine that may use it, **and** to each
   client of the people who may seal it again: every admin's clients for an org route;
   the person's own clients for their own secret. Each client already has a P-256 key (the
   browser's in IndexedDB, non-extractable; the Mac's and the Remote's in the Keychain or
   the Secure Enclave), and its public half is on its client record. A client that is
   online opens its own copy and seals again for a machine that joined later, a client
   that was paired later, or a route that changed.
2. **Cloud credentials.** An AWS access key (and a role), a Google service account and an
   Entra app's secret are sealed to each machine like a key. agentsd makes its own token
   from it (AWS STS, Google OAuth, Entra), at most an hour long, and makes a new one about
   10 minutes before it ends. A member's machine now holds the long-lived credential.
3. **Check on a machine.** `orgRoutes/check` asks one online machine that holds the
   route's current version to check it, and gives back its answer.

Decided: one pull request for the control plane, agentsd, the wire and the three
clients, because the wire change breaks every client at once and a stack would leave
main without a way to set a key between its PRs. Alex can overrule.

## The envelope

HPKE base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM: as `SealOrgRoute`,
`apns.Seal` and Swift's `Envelope` already use. Go: `crypto/hpke`. Swift: CryptoKit's
`HPKE.Ciphersuite.P256_SHA256_AES_GCM_256`. Browser: `@hpke/core` over WebCrypto.

A **recipient** is named `m:<machine id>` or `c:<CLIENT UUID>` (upper case, as the client
record writes it).

### An org route's secret

- Info: `com.alexecollins.agents.orgroute.v3`.
- Associated data, as UTF-8:

  ```text
  orgroute.v3|<route id>|<recipient>|<field>|<sealVersion>|<kind>|<vendor or empty>|<binding>
  ```

- `binding` is the lower-case hex SHA-256 of the route's settings, one line each for those
  present, in this order, each `name=value\n`: `address`, `apiVersion`, `clientID`,
  `header`, `location`, `project`, `region`, `resource`, `tenant`. The control plane
  refuses a setting with a line break in it.

So the admin's client binds each value to **where it goes**: its kind, its API and its
settings. A control plane that changes a route's address, header, region or kind, to send
the key to a server of its own, makes every copy fail to open. The control plane may still
change what does not send the key elsewhere: the name, the runtimes, the model map, the
groups and the default.

### A person's secret

- Info: `com.alexecollins.agents.usersecret.v1`.
- Associated data: `usersecret.v1|<person id>|<recipient>|<NAME>|<version>`.

### Versions

- An org route has `sealVersion`, 1 at its first secret and one more each time its secrets
  or its kind, API or settings change. The admin's client says it; the control plane
  takes only the kept one plus one.
- A person's secret has `version`, above the kept one: the kept one plus one, or for a name
  the client has none of, the time in milliseconds, so it is above a removed one's version,
  which the client cannot see.
- A machine keeps the highest version it has opened of each, and refuses a lower one. So a
  control plane cannot send back an older key after it was replaced.

## What the control plane keeps

- `v1/org/routes/<id>.json`: the route, as before, with `sealVersion`. Its fingerprints
  (the first 8 hex digits of each value's SHA-256) are what the admin's client says.
- `v1/org/routes/<id>.secret.json`: `{id, sealVersion, sealed: {<recipient>: {<field>:
  envelope}}}`. Not sealed with the keeper: each envelope opens only with its recipient's
  key.
- `v1/users/<user>/secrets/<NAME>.json`: `{name, version, updated, sealed: {<recipient>:
  envelope}, machines, leftOn}`.

A copy for a recipient that is no longer one (a removed machine, a forgotten client, an
admin who is not one now, a machine out of the route's groups) is never sent, and is
dropped at the next write. Bounds: at most 200 recipients a value, and a record of at most
4 MiB.

## The methods

| Method | Who | What |
|---|---|---|
| `orgRoutes/recipients {groups}` | an admin | The machines that may use a route for those groups, and the admins' clients. Each `{id, name, publicKey}`. |
| `orgRoutes/set {route, sealed?, rev}` | an admin | As before. `sealed` is `{sealVersion, fingerprint, values: {<recipient>: {<field>: envelope}}}`, every field, for every recipient. Needed when the secrets or the kind, API or settings change. |
| `orgRoutes/replaceKey {id, sealed, rev}` | an admin | New values for every field, sealed. |
| `orgRoutes/sealed {id}` | an admin | This client's own copy of the route's values, to open before a change. |
| `orgRoutes/check {id}` | an admin | Asks a machine (decision 3). |
| `user/secretRecipients` | the person | Their machines that take secrets, and their clients; and `user`, the person's id, for the associated data. |
| `user/setSecret {name, version, values}` | the person | `values` is `{<recipient>: envelope}`. |
| `sealing/work` | a client | Each value this client has a copy of whose recipients are not all sealed to: its own copy, the route's binding, and the recipients missing. |
| `sealing/add {items}` | a client | The new copies. Taken only at the current version, for current recipients. |
| `control/sealingWanted` (notification) | to clients | Something waits to be sealed: call `sealing/work`. |
| `host/orgRouteCheck {id}` | to a machine | `orgRoutes/check` on the machine, with its own copy. |

A client calls `sealing/work` when it connects, and again on `control/sealingWanted`. The
control plane sends that notification to the admins' clients when an eligible machine or an
admin's client has no copy of a route, and to the person's clients when one of their
machines or clients has no copy of a secret.

## A machine that waits

A machine that may use a route but has no copy of it yet gets the route with `waiting:
true` and no secret. The route is no account on that machine until a copy comes, and a
session that needs the organisation's path says "Your organisation's <route> is waiting for
an admin's app to seal its key for this machine." A machine that holds an older seal keeps
using it while it waits for the new one. The admin's row in Console ▸ Model Access says how
many machines wait, and `orgRoutes/mine` says a route waits for one of the caller's
machines. A person's machine that waits for a secret leaves it out of `secrets.env`;
`user/secretNames` names the machines that wait.

Decided: a waiting route is no account on the machine, because an org account shown as not
signed in would offer a sign-in that cannot work. Alex can overrule.

## No migration

v0.x: an existing route's secrets and a person's existing secrets do not open with the new
code. An admin enters each key again; a person sets each secret again. The release notes
say so.

## Known limit until the machine lock

The sealing client gets each machine's and each client's public key from the control
plane. Until the machine lock (#3400) signs these keys on the person's own devices, a
control plane could hand out a key of its own and get a copy sealed to it. The docs say
so.

## Principles (direction.md)

- **6 (holds nothing it could misuse):** this change. The control plane keeps only
  ciphertext it cannot open, and no compute credential for org routes.
- **1 (nothing relies on the Mac):** the web page seals; any client can.
- **2 (three shapes):** the same in hosted, self-hosted and on a Mac control plane. A
  control plane needs no keeper for these secrets any more.
- **7, 8:** it keeps less, and what it keeps is encrypted end to end to the machine.

None is left out. The known limit above is principle 6's, closed by #3400.

## Done when

A test shows that the control plane's store and memory never hold a route's plain value:
a control plane whose keeper fails every open still lets a route reach a machine, and the
machine's relay uses it.
