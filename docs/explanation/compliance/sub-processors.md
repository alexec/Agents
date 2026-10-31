---
diataxis: explanation
devices: [mac, iphone, ipad, web, server]
description: "Every outside company that gets data when you use Agents, what it gets, and whether a self-hosted set-up can leave it out."
---

# Sub-processors

A sub-processor here is an outside company that gets your data when you use Agents. The
people who make Agents run none of these for you, except the hosted service. In a
self-hosted set-up, your organisation holds the account with each one, under that
company's own terms.

Agents itself has no analytics, no tracking and no advertising ([Privacy](../../privacy.md)).

## Always

| Company | Service | What it gets | Can a self-hosted set-up leave it out? |
| --- | --- | --- | --- |
| The vendor of each runtime you use (below) | The model behind the runtime | Your prompts, the files and command output the runtime reads, and its answers | Only by using no runtime of that vendor. A runtime you do not install or sign in sends nothing. |

At least one runtime is needed to run agents.

## Runtime vendors

Each runtime runs on your machine and talks to its own company. Agents does not see that
traffic and does not copy it ([Privacy](../../privacy.md)).

| Runtime | Company | Notes |
| --- | --- | --- |
| Claude | Anthropic | Signs in with a Claude account, or uses a key or a gateway that you pass in its environment (Bedrock, Vertex, a base URL). On a server that borrows a Mac's sign-in, the gateway variables are cleared and its calls go out from that Mac ([Data flow](data-flow.md#a-borrowed-sign-in)). |
| Codex | OpenAI | Refreshes its token at `auth.openai.com`. A server can borrow a Mac's sign-in, as for Claude. |
| Antigravity | Google | A personal or business Google account. Mac machines only. |
| Grok | xAI | Signs in with grok.com. |
| Copilot | GitHub (Microsoft) | Signs in with GitHub. |
| Cursor | Anysphere (Cursor) | Signs in with Cursor. |
| OpenCode | The model provider you sign it in to | Signed out, it uses OpenCode Zen's free models. Sharing is off. |

The model gateways that the Claude row names (Bedrock, Vertex) are your organisation's
accounts, so the data goes to that cloud and not to Anthropic directly. An org key or a
gateway that the organisation sets (#999) sends the data to that provider or gateway, as
[Org keys and gateways](../org-keys-and-gateways.md) says.

## Only when you turn it on

| Company | Service | What it gets | Can a self-hosted set-up leave it out? |
| --- | --- | --- | --- |
| Apple | iCloud (CloudKit), when **Relay for my devices** is on | Requests and updates between the control plane and a phone away from home, each sealed so that only your control plane and that device can read it | Yes. The relay is off until you turn it on. With it off, nothing goes through iCloud. |
| Apple | Apple Push Notification service | A notification's words, sealed with the device's own key; a Live Activity's phase and times, never a title or a line of the chat | Yes. No notifications reach a phone or iPad then. |
| Your store's host | The bucket that holds the control plane's store (S3, MinIO or another S3-compatible service) | The control plane's records (see [Data and retention](data-and-retention.md)); a server's backups, sealed | Yes. The store can be a folder on the control plane's own disk. |
| Google | Cloud KMS, when the control plane uses it | Calls to seal and open the control plane's key. The key in KMS never leaves Google Cloud. | Yes. A control plane can keep its key in a file, or use HashiCorp Vault. |
| GitHub | The github server, GitHub sign-in, git | Issues, pull requests, checks and code of the folders you connect; your git pushes | Yes, if you do not connect GitHub. |
| GitLab (gitlab.com or your own) | The gitlab server, GitLab sign-in | Issues, merge requests and pipelines of the folders you connect | Yes. A self-managed GitLab keeps it in your organisation. |
| Linear | The linear server, Linear sign-in | The issues you read and change | Yes, if you do not connect Linear. |
| Your mail provider | Email over IMAP | Reads one mailbox. Agents never sends mail. | Yes, if you do not connect a mailbox. |
| Each MCP server's maker | Connectors | What your agents send to its tools | Yes. Add only the servers your organisation allows. |
| Docker, AWS, Google Cloud, DigitalOcean, GitHub Codespaces, Coder | Machine providers | The calls that start, stop and make machines, with the credentials you give | Yes. A control plane with no provider calls none. |
| Google, Apple, GitHub | Sign-in of a person to the control plane | An ID token or a device-flow token, once per sign-in | Yes. The local owner signs in with codes and needs no outside account. |
| nodejs.org, npm, GitHub releases, Google, each runtime's maker | Downloads of runtimes | The download requests | Partly. A machine downloads only the runtimes you install. |
| skills.sh, the MCP registries, GitHub | Marketplaces and catalogues | Search and download requests | Partly. An organisation's policy will allow only some marketplaces (T5, #998). |

## A control plane that the makers of Agents run

A self-hosted control plane uses none of these.

**`control.agentloops.dev`**, the control plane in the cloud, is made by `deploy/gcp/up.sh`
([Run the control plane in the cloud](../../how-to/run-the-control-plane-in-the-cloud.md)):

| Company | Service | What it gets |
| --- | --- | --- |
| Google | One Compute Engine VM in `us-west1`, and Cloud KMS | The control plane's store, on the VM's disk. KMS seals the control key. |
| Cloudflare | DNS | The names only. Cloudflare does not carry the traffic. |
| Let's Encrypt | TLS certificates | The names that the certificates are for. |
| Apple | Apple Push Notification service | As above, for phones with no Mac machine. |

**The hosted service** ([Run the hosted service](../../how-to/run-the-hosted-service.md))
gives each account a control plane of its own, with its records under `accounts/<id>/` in
the store and its control key sealed by Google Cloud KMS. It runs on any machine with
Docker. Sign-up with GitHub reads your GitHub user id and login once, and then forgets the
token ([Privacy](../../privacy.md#the-hosted-service)).

## Delivering the apps

| Company | Service | What it gets |
| --- | --- | --- |
| Apple | TestFlight, and the App Store | Delivers the Mac window and the Remote. What Apple keeps about a tester or a buyer is under Apple's terms. Agents adds nothing to it. |
| GitHub | Releases | Delivers Agents Host. |
| GitHub | Pages | Serves this docs site. |

## Related

- [Data flow](data-flow.md)
- [Integrations](../../reference/integrations.md)
- [Runtimes](../../reference/runtimes.md)
