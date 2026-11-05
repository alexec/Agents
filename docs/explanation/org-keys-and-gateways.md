---
diataxis: explanation
description: How an organisation's keys and model gateways are kept, sent to machines, and what that does not protect against.
---

# Org keys and gateways

An organisation can pay for the model itself: with an API key of the runtime's own vendor
(an **org key**), or through a **gateway** (Amazon Bedrock, Google Vertex AI, Microsoft
Azure, or its own base URL, such as LiteLLM). An admin keeps each as an **org route**.
Each member's machines show the route as an account of the runtimes it serves (spec 999,
#999). This page tells where a route's secrets are, and why.

## Where a route is kept

The control plane keeps two objects for each route in its store:

- `v1/org/routes/<id>.json`: the route. It has its name, kind, runtimes, settings, model
  map, groups, version and seal version. It has no secret. For each secret it has only the
  field's name and a fingerprint, the first 8 hex digits of its SHA-256, which the admin's
  app works out, so that two admins can compare.
- `v1/org/routes/<id>.secret.json`: the secrets, as the admin's app sealed them: one
  envelope for each field and each recipient. Nothing in it opens with a key the control
  plane holds.

Nobody can read a value back after it is saved, also not an admin. **Replace Key** writes a
new value. The control plane needs no keeper for these secrets (#3397,
`specs/3397-client-sealing`).

## How a route gets to a machine

Each machine has its own P-256 key, and so has each app (the web page, the Mac window, the
Remote); the control plane has their public halves. When an admin saves a route, the
admin's app asks the control plane for the **recipients**: each machine whose person may use
the route, and each admin's app. It seals each value to each of them with HPKE (P-256,
HKDF-SHA256, AES-256-GCM), and sends only the envelopes. The associated data is the route,
the recipient, the field, the seal version, and where the key goes: its kind, its API and a
digest of its settings (the address, the header, the region and the rest).

The control plane sends each machine its own envelopes on the machine's channel 0
(`host/orgRoutes`) within 5 seconds, from every copy.

- The control plane cannot open an envelope: it has no recipient's private key.
- A relay, a log or another copy that sees the message cannot open it.
- A file copied to another machine does not open there.
- A control plane that changes a route's address, header, region or kind, to send the key
  to a server of its own, makes every envelope fail to open.
- An older seal cannot take the place of a newer one: each machine keeps the highest it has
  opened.
- Only the machines of the people the route is for get it: everyone, or the groups the
  admin names. A machine that does not say `host.org-routes/2` gets nothing.

### A machine that joins later

A machine that joins after the route was saved, or whose person joins one of the route's
groups, has no envelope yet. It gets the route as **waiting**, and it is no account on that
machine. The control plane says `control/sealingWanted` to the admins' apps. The next one
that is open opens its own copy, seals the values to the machine, and sends the new
envelopes (`sealing/work`, `sealing/add`). Console ▸ Model Access says how many machines
wait, and a person's Organisation Policy says that a route waits for one of their machines.
An app paired later gets its copy the same way.

A person's own secrets (Machines ▸ Secrets) are sealed the same way, by the person's app, to
the person's machines and apps.

## Cloud credentials go to the machine, sealed

An AWS access key (and a role to assume), a Google service account and an Entra app's
secret last until somebody revokes them. The admin's app seals them to each machine like a
key. The machine makes a token from each one (AWS STS, Google OAuth, Entra) that ends within
an hour, keeps it in memory only, and makes a new one about 10 minutes before the old one
ends. An offline machine loses that gateway within an hour.

So a member's machine now holds the long-lived credential, sealed, and opens it in memory to
make a token. Give the access key a role with the least rights it needs, and prefer a Bedrock
API key, an Azure key or a gateway's key, which a provider can scope and revoke on its own.

A plain key (an Anthropic, OpenAI or xAI key, a Bedrock API key, an Azure key, or a
gateway's key) goes to the machine as it is, sealed. It works offline.

**Check** asks an online machine that holds the route to send one small request with it,
because the control plane cannot open the key.

## What this does not protect against

- **The control plane gives out the apps' public keys.** The admin's app gets each
  machine's and each app's public key from the control plane. It seals to a machine only
  when that machine's key is in its person's machine lock (#3491), which the person's own
  devices sign, so a control plane cannot give out a machine key of its own. A machine
  that is not in the lock yet gets its copy once its person approves it. An app's key is
  not in the lock: a control plane that is compromised or misused could give out an app
  key of its own, and get a copy sealed to it.
- **Agents Host runs as the member.** Hosts never escalate. A member who reads the
  machine's memory with a debugger while a request is sent can find a key that is open
  there. Sealing keeps keys out of files, logs, messages and the runtime's environment. It
  does not keep them from the member's own account.
- **On Linux, the member's other programs can read the machine's key.** On a Mac the key
  is in a Keychain item that only agentsd can read. A Linux machine keeps it in the file
  `control-host-key` in the root (0600), so any process of the same user, an agent's shell
  included, can read it and open the routes the machine keeps. Run agentsd as a user of
  its own on a Linux machine where that matters.
- **A leaked key stays valid until the provider revokes it.** Revoke it at the provider
  first. Then replace it here, or turn on the policy's kill switch.

## No migration

The routes and the secrets that an older control plane sealed with its keeper do not open
with this one. Enter each route's key again in Console ▸ Model Access, and each of your
secrets again in Machines ▸ Secrets.

## The policy

The organisation's policy can require the org path for a runtime: `runtimes.<id>.reach`
lists the ways allowed (`signIn`, `orgKey`, `gateway`). Its `notices.antigravityTerms`
says whether members see Google's terms notice for Antigravity (`show`), not see it
(`accepted`), or cannot use Antigravity (`refuse`). A machine needs `host.org-routes/2` to
follow either rule.

## See also

- [Add an org key or a gateway](../how-to/add-an-org-key-or-gateway.md): Console ▸ Model
  Access, and the policy's two rules.
