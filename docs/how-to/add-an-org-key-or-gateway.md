---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Give your organisation's people one key or one model gateway (Amazon Bedrock, Google Vertex AI, Microsoft Azure, a base URL) in Console ▸ Model Access, and require it with the policy.
---

# Add an org key or a gateway

An **org route** is your organisation's way to the model (#999): an API key that the
organisation pays for, or a gateway. Each member's machines use it as one more account of
the runtimes that it serves. No member sees the key, and the runtime never has it. See
[Org keys and gateways](../explanation/org-keys-and-gateways.md) for why.

**Not on machines yet.** The Console keeps routes, sends them to machines and keeps the two
policy rules below. Agents Host uses a route, and refuses a person's own sign-in under
**Org key or gateway only**, from a later release (#999, slice 2). Until then, each runtime
uses each person's own sign-in.

## Before you start

- You are an admin of the control plane, and you use the web page. Console ▸ Model Access
  is on the web page only.
- The control plane has a keeper for secrets: a key file, or `AGENTS_CONTROL_KMS`. Without
  one, Model Access says so, and keeps no route that has a key.
- You have the key or the credentials from the provider. Each kind below says what to get.

## Which runtimes can use which kind

| Runtime | Org key | Amazon Bedrock | Google Vertex AI | Microsoft Azure | Gateway (base URL) |
|---|---|---|---|---|---|
| Claude | Anthropic key | Yes | Yes | Yes | Yes |
| Codex | OpenAI key | No | No | Yes | Yes |
| Gemini | Gemini API key | No | Yes | No | Yes |
| OpenCode | Anthropic or OpenAI key | Yes | Yes | Yes | Yes |

Cursor, Copilot, Antigravity and Grok cannot use a route: their model traffic cannot go
through the machine's relay. They use each person's own sign-in.

## Add a route

1. On the web page, choose **Console** at the top, then **Model Access**.
2. Choose **Add Route…**.
3. Type the **Name members see**, for example "Acme Bedrock".
4. Choose the **Kind**. For an org key, Azure or a gateway, also choose the API that it
   **Speaks**: Anthropic, OpenAI or Google Gemini.
5. Choose the runtimes that it is **For**. Choose **Default** beside a runtime to make the
   route the account that each member's new sessions of that runtime use, unless the member
   chooses another.
6. Type the settings and the key for the kind:
   - **Org key**: the **API key** from the vendor's console (Anthropic Console, OpenAI
     Platform or Google AI Studio).
   - **Amazon Bedrock**: the **AWS region**, and a **Bedrock API key**, or an **AWS access
     key id** and **its secret**. With an access key you can also give a **Role to assume**
     and its **External id**. The control plane makes a token from them that lasts up to one
     hour, and sends only the token to machines.
   - **Google Vertex AI**: the **Google Cloud project**, the **Location**, and the **Service
     account key (JSON)** of a service account that may call Vertex AI. The control plane
     sends machines a token that lasts up to one hour.
   - **Microsoft Azure**: the **Resource** name or its address, and an **Azure key**, or an
     Entra app's **tenant**, **client id** and **secret**.
   - **Gateway**: the gateway's **Address** (https), the **Header for the key** if it is not
     `Authorization`, and the **Key**.
7. If the gateway names models differently, type a **Model map**: one line for each model,
   the runtime's id, then `=`, then the gateway's id. For example
   `claude-sonnet-4-5 = us.anthropic.claude-sonnet-4-5-v1:0`.
8. Choose **Who may use it**: no group for everyone, or the groups that may.
9. Choose **Add Route**.

Each online machine of each person who may use it gets the route within seconds. The key
field is empty after you save. The list shows the first 8 hex digits of each key's SHA-256,
so that two admins can compare keys without seeing them.

## Check, edit, replace the key, remove

- **Check** sends one small request to the provider from the control plane, where it can
  (keys and gateways), and says the answer.
- **Edit…** changes the name, runtimes, settings, model map and who may use it. A key field
  that you leave empty keeps its key.
- **Replace Key…** writes a new key. The route's version goes up, and each machine uses the
  new key from its next request.
- **Remove…** asks first. Each machine deletes its copy, and the sessions on the route stop
  at their next turn.

The **Machines** column says how many machines hold the route's newest version.

## Require the org path

To make members use the organisation's route and not their own sign-in:

1. Choose **Console ▸ Policy**.
2. Under **Ways to the Model**, set **Claude reaches the model by** (or another runtime) to
   **Org key or gateway only**.
3. Read **What Changes**. If no route serves that runtime, it says that nobody can start it.
4. Choose **Save**.

Each member's own sign-in for that runtime is then refused with **Set by your
organisation**, and the runtime's own variables are taken out of their pass-through, so
that they cannot point it at another gateway.

Under the same heading, **Antigravity's terms** decides Google's terms notice for every
member: **Show the notice**, **Reviewed by your organisation** (members do not see it), or
**Do not allow** (Antigravity is refused).

## What members see

Every person sees the routes that they may use in Settings ▸ Policy, on the Mac, the iPhone,
the iPad and the web page: each route's name, its kind, its runtimes and **From your
organisation**. They never see a key, a fingerprint, a region or an address.

## See also

- [Org keys and gateways](../explanation/org-keys-and-gateways.md)
- [Set an organisation policy](set-an-organisation-policy.md)
- [Policy](../reference/policy.md)
