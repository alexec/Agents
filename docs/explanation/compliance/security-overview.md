---
diataxis: explanation
devices: [mac, iphone, ipad, web, server]
description: "How Agents keeps your organisation's machines and data safe: people, keys and sign-in, the audit, sandboxes, where secrets live, logs, the coming policy, and how to report a vulnerability."
---

# Security overview

This page says how Agents protects your machines and your data today, for an
organisation's security team. Where something is planned and not built, it says so and
names its issue.

## The shape

- **Every connection goes out.** Each client and each machine connects out to the control
  plane. No machine needs a port open to it. See [The control plane](../control-plane.md).
- **The control plane routes and remembers little.** It knows who is paired and which
  machines there are. Agents, conversations, files and runtime sign-ins stay on the machine
  that runs them.
- **Machines never escalate.** Agents Host and `agentsd` run as the machine's user. On a Mac
  they are the user's own login items (`SMAppService.agent`). On Linux they are a
  `systemctl --user` service. Nothing asks for admin rights, and nothing installs a
  privileged helper. A machine provider's start script for Google Compute Engine runs as
  root only to make an `agents` user, and the machine runs as that user.

## People and roles

- **People** (T1, #994). Every client belongs to a person, and every machine to one user.
  A person reaches only their own machines. A call to another person's machine is answered
  as if there were no such machine. See [People and machines](../people-and-machines.md).
- **Roles.** An admin or a member. The first person, the **local owner**, is an admin. A
  control plane always keeps one admin at least. A **bot** is a user that admins make for
  team workflows.
- **What an admin sees.** People, their clients by name, and their machines by name and
  state. Not another person's folders, agents or files.
- **Removing a person** cuts off their clients and their machines on every copy of the
  control plane within 5 seconds.

## Sign-in

- **The local owner** signs in with the codes that Agents Host and `agents-control` make. No
  outside account is needed, also on a control plane on the internet.
- **Google and Apple** (T2, #995). The control plane checks the ID token against the
  provider's keys, its issuer, audience and expiry, and a nonce bound to that control
  plane. Google can be limited to your Workspace domains.
- **GitHub.** A GitHub App with the device flow and user tokens that expire. The control
  plane reads the user once, then forgets the token. A GitHub person joins only by invite,
  and each further client of theirs needs approval on a client that is signed in. GitHub can
  be limited to your organisations.
- **Your own identity provider** (OIDC: Okta, Entra) and SCIM are planned (T9, #1002).

## Keys

- **Pairing.** A code works once, for five minutes. An invite lasts 7 days. A machine that
  asks to join with no code waits at most 10 minutes for approval.
- **Each connection proves its key.** A client or machine keeps a P-256 key of its own
  (in the Secure Enclave on an iPhone or iPad that has one). A Mac's machine key is in a
  Keychain item that only agentsd's code signature can read. A Linux machine's key is the
  file `control-host-key` in its root (0600): any process of that user can read it (spec 999,
  "Limits"). At each connection, both
  sides prove their keys with HMAC-SHA256 over a nonce exchange, under a key from P-256
  ECDH and HKDF. The proof is bound to the address it was made for, and must arrive within
  15 seconds.
- **Key lifetimes** (T4, #997). A client's or a machine's key expires 90 days after it was
  paired. The control plane renews it while it is in use. `agents-control serve --key-days`
  sets another lifetime.
- **Rotation.** An admin can rotate the control plane's own key. Nobody pairs again. The old
  key is still accepted for 30 days.
- **Failed proofs are limited.** After 20 failed proofs in a minute from one address, that
  address is refused for a minute.
- **The browser** keeps a key that script can use but not read. Its listener is on
  `localhost` only, and refuses requests for other addresses and other origins.

## The one grant

Every client of a person can do everything that person can: start and stop agents, open
terminals, sign runtimes in, and pair and forget clients. There is one grant, not two,
since #111. A lost phone can do these things until you forget it from another screen.
Forgetting cuts it off at once. See
[One grant for every client](../control-plane.md#one-grant-for-every-client).

## The machine lock

A machine takes a request only when one of its person's own devices vouches for it (#3399,
#3492). Each person has a machine lock: a chain of entries, each signed by one of their
devices, that names their clients and their machines. The control plane keeps the chain and
signs nothing in it.

- **Each request is checked by the machine.** A client opens a channel to each machine with
  a new P-256 ECDH key, signed with its lock key (ECDSA P-256, in the Secure Enclave where
  there is one; a key that script cannot read in the browser). The machine answers with its
  own, signed with its machine key. HKDF-SHA256 makes a key for each direction, and each
  request and answer carries an HMAC-SHA256 and a count. Requests are signed, not encrypted.
- **A kept request** for a machine that is away is signed by the client, and taken once, at
  most a day later. **A machine's call to another machine** of the same person is signed by
  that machine, and limited to starting and calling a session, and sending and bringing back
  a folder.
- **What the control plane may ask unsigned:** whether a machine is there, its sessions and
  worktrees, a backup, and a clone for a new workspace. Nothing that starts an agent, runs a
  command or reads a file.
- **A new device or machine** joins the lock only when one of the person's devices approves
  it, with six digits that both screens show and that the control plane cannot choose.
- **A recovery key** (#3493) is made with the lock and shown once, to keep in a password
  manager: 128 random bits as 32 letters and digits. It is a key of the lock, so a person who
  lost every device types it on a new one, which adds itself. The lock holds the key's
  private half sealed (AES-256-GCM) under a key made from those bits, which the control plane
  never sees. With no device and no recovery key, the person starts a new lock: each machine
  refuses it until its own account runs `agentsd lock reset` in its shell.

What the control plane can and cannot do:

| It can | It cannot |
|---|---|
| route, or refuse to route, any request | add a client or a machine to a lock |
| read requests and answers (they are signed, not encrypted) | send a request that a machine takes as a client's |
| keep the chain, and keep it back from a machine | change or remove an entry, or put one in a different order |
| sign the org policy, which can only make a machine do less | give a client a machine key of its own to seal to |
| ask a machine for its sessions and worktrees, a backup, or a clone | start an agent, run a command or read a file on a machine |
| fire a workflow that the person set up on a machine | change what a machine answers, or show a card it did not raise |
| serve a changed web page | sign with a Mac's or a phone's key |

**Limits.** A control plane that serves a changed web page can use that browser's key while
the page is open; the Mac and the Remote are signed apps and do not have this limit. The person in
a machine's audit is still the control plane's word; the client is the lock's (#3543). The control plane can always refuse
to route. See [What the control plane can and cannot do](../control-plane.md#what-the-control-plane-can-and-cannot-do).

## Who did what
## Who did what

Each change made on a machine through the control plane carries its **actor**: the
person, the client and the time (T3, #996). The control plane stamps it from the key that
was proved, never from what the client says. Starting, stopping and deleting agents,
answering cards and changing settings are recorded. Reads and prompts are not.

- **Where:** Events ▸ Audit on the Mac, the Remote and the web page, and Console ▸ Audit.
  A member sees only their own entries. See [Events](../../reference/events.md#audit-who-did-what).
- **How long:** 90 days by default. An admin sets 1 to 3,650 days.
- **Export:** an admin exports the entries as CSV or JSON lines.
- **Tamper-evident:** each entry carries the hash of the one before it, in a chain for
  each copy of the control plane, and a seal for each day holds each chain's head
  (T8, #1001). `agents-control audit verify` says which entry was changed or removed. See
  [Events](../../reference/events.md#the-hash-chain).
- **Sinks:** an admin sends each entry, as it is written, to syslog (RFC 5424 over TCP or
  TLS) or to HTTP (JSON lines), from Console ▸ Audit ▸ Sinks. A copy outside the control
  plane's store is out of reach of a person who can change the store. See
  [Events](../../reference/events.md#sinks).

## Sandboxes

Agents has no operating-system sandbox of its own. It turns on each runtime's own sandbox
(spec 064):

| Runtime | Its sandbox |
| --- | --- |
| Claude | Claude Code's sandbox, on or off |
| Codex | Read only, or full access |
| Grok | `--sandbox workspace`, or off |
| Cursor, Copilot | The runtime decides |
| Antigravity, OpenCode | None |

Each machine sets a default for each runtime, and each agent can change it. The default is
the runtime's own setting. A helper that an agent with a sandbox starts cannot turn its
sandbox off. If a sandbox fails to start, the agent stops and asks you what to do.

An organisation will be able to require a sandbox by policy (T5, below).

## Access on the machine

- **`daemon.sock`**, the machine's local socket, is mode 0600. On a Mac, the caller must be the
  same macOS user, and its role comes from its code signature, which the `agents-peer`
  helper checks against the team. On Linux, only the user's own ssh session gets the full
  role.
- **The app's own tools** are served on `127.0.0.1` only, with a new token each time a
  runtime starts. The token is sent as a header, never put in an environment, and is taken
  back when the runtime ends.
- **What a runtime's environment holds.** A runtime gets only an allow-list of variables
  (`PATH`, `HOME`, locale, proxies, CA files, toolchain homes, and its own prefix, such as
  `ANTHROPIC_` for Claude). MCP servers and the terminals you open get the whole login
  environment.

## Where secrets live

| Secret | Mac | Linux |
| --- | --- | --- |
| GitHub, GitLab, Linear and mail connections | Keychain | `~/.agents-secrets/connections.json`, mode 0600 |
| A runtime's own sign-in | Where the runtime keeps it (Claude: its Keychain item, read only) | Where the runtime keeps it |
| Runtime keys that a Mac lends to its servers | Keychain, this device only, when unlocked | Borrowed for each run |
| MCP sign-ins (OAuth) | `~/.agents-secrets/mcp-sign-ins.json`, mode 0600 | The same |
| A person's secrets from the control plane | `~/.agents-secrets/secrets.env`, mode 0600 | The same |
| A secret with Ask before use (#4014) | `~/.agents-secrets/sealed.json`, mode 0600, sealed under a key made from the machine's key, which is in the Keychain: an agent can read the file but cannot open it | The same, but the machine's key is a 0600 file. A second layer under a release key that the control plane keeps comes next. |
| A machine provider's tokens and keys, on the machine that carries it (#3398) | `~/.agents-secrets/provider-secrets.json`, mode 0600 | The same |
| The machine's own key | A file of mode 0600 in its data folder | The same |
| The control plane's key | Keychain (Agents Host), or a file of mode 0600 | A file of mode 0600, or sealed in the store by KMS |

An iPhone or iPad keeps its own key in the Secure Enclave where it has one, else in the
Keychain, on this device only.

A person's own secrets and the organisation's **org keys** (#999) are sealed by a client
(the web page, the Mac window or the Remote) with HPKE (P-256, HKDF-SHA256, AES-256-GCM)
straight to each machine that may use them, and to each app that may seal them again
(#3397). The control plane keeps and forwards only that ciphertext: it holds no key that
opens it, in its store or in its memory. Each envelope is bound to its machine, its field,
its version and, for an org key, to where the key goes, so a control plane that changes a
gateway's address cannot get the key sent elsewhere. The client seals to a machine only
when the machine's key is in its person's machine lock (#3491), signed by that person's
own devices, so a misused control plane cannot hand out a machine key of its own. An app's
key still comes from the control plane; see [Org keys and gateways](../org-keys-and-gateways.md).

The control plane holds no machine provider's secret (#3398): a provider runs on one of
its person's machines, which keeps its tokens and keys and runs its server, and the
control plane sends it each list, start and stop. The tokens go through the control plane
once, on their way to that machine, over TLS, not sealed to it: a control plane could read
them as they pass.

## Logs

| Log | Where | What it holds | Size |
| --- | --- | --- | --- |
| `daemon.log` | `~/Library/Logs/Agents` on a Mac, `$XDG_STATE_HOME/agents/logs` on Linux | What the machine did | Rolls at 4 MB, keeps one older file |
| `control.log` | Agents Host's log folder, or the container's output in the cloud | Joins, people, keys, sign-in changes, refused connections with their address | Rolls at 4 MB, keeps one older file |
| `machine-relay.log` | The Mac's log folder | The sign-in relay (what was asked and how it was answered) | 1 MB |
| `app-tools.jsonl` | Each agent's folder | Every call to the app's own tools, with a `token` argument left out and answers cut to 2,000 characters | Deleted with the agent |

The code does not write tokens to these logs. **Redaction** (T8, #1001) also cuts known
token shapes out of each transcript line, each `app-tools.jsonl` line and each line that
`agentsd` writes to `daemon.log`, before it is written. A match becomes
`[redacted:<kind>]`, and the clients get the redacted line too. The shapes are GitHub,
GitLab, Anthropic, OpenAI, Stripe, AWS access key, Google API key, Slack and npm tokens,
JWTs, private key blocks, the token after `Bearer`, and the control plane's codes.
Redaction is always on. A token that the runtime streams in two message chunks is caught
too: the end of each chunk that could start a token waits for the next one (at most 256
bytes). The report of a turn says its last message redacted as well.

Redaction does not catch:

- text that is not a known shape, such as a password in plain words;
- what a runtime writes to its standard error, and what Agents Host writes to `daemon.log`;
- the runtimes' own session files (see [Erasure](data-and-retention.md#erasure)).

`control.log` cuts out codes, `Bearer` tokens, `token=`, `secret=` and `password=`
values, and the same known token shapes (#1001). Agents Host's diagnostics bundle masks codes, secrets, tokens, passwords, keys, and
long base64 and hex strings.

## The web page

The page that a control plane serves is checked against a list of its files' hashes. It
sends a content security policy, `frame-ancestors 'none'`, no referrer, and HSTS for a year
on a public address. It sets no cookies, and draws nothing that an agent wrote as HTML.

## Organisation policy (coming in 0.11)

Policy from the control plane is roadmap step T5 (#998). Its spec is
`specs/998-org-policy/` (pull request #2164). It is not built yet. It gives an admin one
signed policy, sent to every machine, as a ceiling above each person's settings:

- the loosest mode allowed;
- a required sandbox;
- the runtimes and models allowed;
- the marketplaces allowed;
- dollar and token budgets per person per day;
- caps on helpers;
- the environment variables that may be passed to runtimes;
- a kill switch that stops every turn and pauses every workflow.

A machine that cannot reach the control plane keeps the last policy it had. MDM on a Mac and
`/etc/agents/policy.json` on Linux only pin which control plane a machine must join.

Policy stops mistakes and ordinary use. It is not a boundary against a machine's own user:
the machine runs as that user, who can change the program.

## Report a vulnerability

Report it privately on the folder's GitHub page: **Security ▸ Report a vulnerability**.
Do not open a public issue for it. Each release has a security review of what changed
since the last one.

## Related

- [Data flow](data-flow.md)
- [Data and retention](data-and-retention.md)
- [The control plane](../control-plane.md)
- [People and machines](../people-and-machines.md)
