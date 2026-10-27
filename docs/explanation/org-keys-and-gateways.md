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
  map, groups and version. It has no secret. For each secret it has only the field's name
  and a fingerprint, the first 8 hex digits of its SHA-256, so that two admins can compare.
- `v1/org/routes/<id>.secret.json`: the secrets, in one envelope. The control plane seals
  it with its keeper for secrets (Cloud KMS, Vault or the local key file), as it seals a
  person's own secrets, and binds it to this store key. The store holds only ciphertext.

A control plane with no keeper for secrets refuses a route that has a secret. Nobody can
read a value back after it is saved, also not an admin. **Replace Key** writes a new
value.

## How a route gets to a machine

Each machine has its own P-256 key; the control plane has its public half. When a route
changes, the control plane opens the envelope and seals each value again, with HPKE
(P-256, HKDF-SHA256, AES-256-GCM), to the key of each machine that may use the route. The
associated data is the route, the machine and the route's version. It sends the result on
the machine's channel 0 (`host/orgRoutes`) within 5 seconds, from every copy.

- A relay, a log or another copy that sees the message cannot open it.
- A file copied to another machine does not open there.
- An older version cannot take the place of a newer one.
- Only the machines of the people the route is for get it: everyone, or the groups the
  admin names. A machine that does not say `host.org-routes/1` gets nothing.

## Cloud credentials stay on the control plane

An AWS access key (and a role to assume), a Google service account and an Entra app's
secret last until somebody revokes them. The control plane keeps these and never sends
them. It makes a token from each one (AWS STS, Google OAuth, Entra) and sends that token,
sealed, to each machine. The token ends within an hour. A new token goes out about 10
minutes before the old one ends. An offline machine loses that gateway within an hour.

A plain key (an Anthropic, OpenAI, Gemini or xAI key, a Bedrock API key, an Azure key, or a
gateway's key) goes to the machine as it is, sealed. It works offline.

## What this does not protect against

- **Agents Host runs as the member.** Hosts never escalate. A member who reads the
  machine's memory with a debugger while a request is sent can find a key that is open
  there. Sealing keeps keys out of files, logs, messages and the runtime's environment. It
  does not keep them from the member's own account.
- **A leaked key stays valid until the provider revokes it.** Revoke it at the provider
  first. Then replace it here, or turn on the policy's kill switch.
- **The control plane opens every route.** Whoever can run the control plane with its
  keeper can read the routes. Keep the keeper's access as tight as the store's.

## The policy

The organisation's policy can require the org path for a runtime: `runtimes.<id>.reach`
lists the ways allowed (`signIn`, `orgKey`, `gateway`). Its `notices.antigravityTerms`
says whether members see Google's terms notice for Antigravity (`show`), not see it
(`accepted`), or cannot use Antigravity (`refuse`). A machine needs `host.org-routes/1` to
follow either rule.

## See also

- [Add an org key or a gateway](../how-to/add-an-org-key-or-gateway.md): Console ▸ Model
  Access, and the policy's two rules.
