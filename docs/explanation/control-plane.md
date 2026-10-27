---
diataxis: explanation
description: What the control plane is, where you run it, what happens when it stops, and why every window, phone and machine goes through it.
devices: [mac, iphone, ipad, server]
---

# The control plane

Every screen you use Agents on, and every machine your agents run on, connects to one
service of your own: the control plane. This page explains what it is made of, where you
can run it, what happens when it or what it remembers cannot be reached, and why the app is
built around it.

## Machines, clients and the control plane

A **machine** runs agents. Your Mac is one, once Agents Host is installed on
it. A Linux server is another, and so is a second Mac. A machine owns its agents: it starts
their runtimes, holds their conversations and keeps their records on its own disk.

A **client** is a screen: the Agents window on a Mac, Agents on an iPhone or iPad, or a
browser on the Mac that runs the control plane. A client runs nothing. It shows what the machines hold and passes on what you type and click.

The **control plane** sits between them. Every machine and every client connects to it, and
it sends each request to the machine it concerns and each update to the clients that should
hear it. A client never connects to a machine on another machine directly, and a machine never
needs to be reached: it connects out, like a client does. The one exception is the same
machine: the window on a Mac reaches that Mac's own machine directly (see
[The window and this Mac's machine](#the-window-and-this-macs-machine)).

So a server you add once is seen by every window and phone, with nothing to set up on each
one, and who may do what is decided in one place.

Every arrow points the way its connection is made. Everything connects out to the control
plane, and nothing connects in to a machine.

```text
                      ┌───────────────────────── CLIENTS ──────────────────────────┐
                      │                                                            │
                      │   Agents window (Mac)              Agents (iPhone, iPad)   │
                      │   sandboxed, runs nothing          a browser on this Mac   │
                      │   each may do everything                                   │
                      └─────────────┬──────────────────────────────┬───────────────┘
                                    │ wss://, paired by code       │ wss://
                                    ▼                              ▼
┌──────────────────────────── CONTROL PLANE (yours) ──────────────────────────────────┐
│                                                                                     │
│   optional load balancer, such as Caddy, ending TLS                                 │
│          │                                                                          │
│   ┌──────▼───────┐   copies link   ┌──────────────┐     one or more copies:         │
│   │ copy A       │◄───────────────►│ copy B       │     - a channel for each        │
│   │              │   to each other │              │       client and machine pair      │
│   └──────┬───────┘                 └──────┬───────┘     - checks each client's      │
│          └──────────────┬─────────────────┘               key, and nothing else     │
│                         ▼                                                           │
│              ┌─────────────────────┐   who is paired, and of what kind; which       │
│              │ store: folder or S3 │   machines there are; codes not yet used;         │
│              └─────────────────────┘   settings                                     │
└──────────────▲───────────────────────────────▲──────────────────────────────▲───────┘
               │ connects out, joined          │ connects out                 │ connects out
               │ by a join code                │                              │
┌──────────────┴────────────┐   ┌──────────────┴────────────┐   ┌─────────────┴──────────────┐
│ MACHINE: this Mac            │   │ MACHINE: another Mac         │   │ MACHINE: a Linux server       │
│ Agents Host               │   │ Agents Host,              │   │ agentsd, installed over    │
│  ├ agentsd                │   │ Join one elsewhere        │   │ ssh or by one command      │
│  ├ agents-control, if the │   │  ├ agentsd                │   │                            │
│  │ control plane runs here│   │  └ agents-relay, optional │   │                            │
│  └ agents-relay, optional │   │                           │   │                            │
│ folders, agents,         │   │ folders, agents,         │   │ folders, agents,          │
│ runtimes, files, terminals│   │ runtimes                  │   │ runtimes                   │
└──────────────┬────────────┘   └───────────────────────────┘   └────────────────────────────┘
               │ agents-relay, when Relay for my devices is on
               ▼
     your iCloud mailbox ──► iPhone and iPad away from home, and notifications
```

Your agents, their conversations, files and terminals, and the runtimes' sign-ins stay on
the machine they belong to. The control plane's store only remembers who is paired and which
machines there are.

## People

Every client belongs to a person, and every machine (a machine) to one user (#994). A person
reaches only their own machines: the control plane opens a client's channels only to its
person's machines, and a call to another person's machine is answered as if there were
no such machine. The first person is the **local owner**, who holds the control plane's
key, and an **admin**. With one person, everything below is as it was. See
[People and machines](people-and-machines.md).

## One grant for every client

Each client is paired once, with a code the control plane shows, and may then do
everything its person's other clients may: start and stop agents on their machines, open terminals,
sign runtimes in, add and remove machines and folders, set helper limits, and pair or forget
other clients. A window, an iPhone, an iPad and a browser are all the same in this.

There used to be two grants, **operator** and **device**, and a phone was a device. That
was retired on 2026-10-02 (#111): a device could already start agents and open terminals
on any machine, so it could run any command there, and the split protected the machines very
little while asking a question on every pairing sheet. What it cost, accepted: a lost
phone or a hijacked browser tab can pair more clients, forget yours, add machines or sign
runtimes in, until you forget it from another screen.

What still tells clients apart is who they are, not what they may do. A phone's or a
browser's connection to a machine is bound to that one client: it reports where you are as
itself, and can't speak as another. An agent's own connection to its machine still reaches
only its tools, and anything else on the Mac reaches nothing.

You can forget a client in **Settings ▸ Control plane ▸ Clients**; forgetting cuts it off at
once, at home and away. Any client may be forgotten, the last one too: Agents Host, on the
control plane's own Mac, can always make a new code.

Older builds keep working. A record, a code or a channel still carries the word `grant`,
always `operator`, which an older copy, machine, Remote or web page reads as everything; a
record written before as `device` is read as a full client. An older window that tries to
change a grant is told there is nothing to change.

## Key lifetimes and rotation

A client's or a machine's key expires 90 days after it was paired (#997). The control
plane renews it while it is in use: on each connection, and every hour for a connection
that stays open, once the key is in its last 30 days. Every connection already proves the
key, so renewal needs nothing from the client and shows no screen. A key that nobody used
for 90 days is refused as expired. The Remote and the web page then ask for a new code, as
they do for a forgotten one. A key paired before this counts from when it was last used.
`agents-control serve --key-days N` (or `AGENTS_CONTROL_KEY_DAYS`) sets another lifetime.

An admin can rotate the control plane's own key with **Rotate Control Key…** in
**Settings ▸ People**, on the Mac, the Remote and the web page. Nobody pairs again:

- The control plane makes a new key, keeps it where it kept the old one (the key file, or
  sealed in the store), and keeps the old one beside it for 30 days.
- It closes every connection. Each client and machine connects again with the key it
  trusts, and its `ok` gives it the new key, with a proof that only the holder of the old
  key could make. From then on it trusts the new key.
- A client or machine that was away connects the same way when it is back. One away for
  more than 30 days pairs again.

A control plane that is given its key (`AGENTS_CONTROL_KEY` or `--key-fd`) has nowhere to
keep a new one, and one that runs as several copies proves itself to its copies with the
key. Both refuse to rotate, and say why. Rotating does not change who anyone is: the local
owner is still the admin.

## Policy

An organisation can have **one policy**: a document of rules that is a ceiling above each
person's own settings (#998, spec `specs/998-org-policy/`). Only an admin can change it. A
control plane with no policy works as before: it tells each machine "no policy", and
nothing changes.

- **One document.** The store keeps it at `v1/policy.json`, with the signature in
  `v1/policy.sig`. Each version is also kept, as it was, in `v1/policy/versions/` (the
  newest 100), so that an admin can see what each change did.
- **Signed by the control key.** Each change is one version higher, and the control plane
  signs it with its key (ECDSA P-256, the key that machines already trust). Any copy can send
  the signed policy without the key. At a key rotation, the control plane signs the policy
  again with the new key.
- **Sent to every machine.** A machine that says the capability `machine.policy/1` gets the
  policy on its channel 0 when it connects, and within 5 seconds of each change, on every
  copy. It tells the control plane which version it keeps (`machine/policyApplied`). A machine
  that does not say the capability gets nothing.
- **Only an admin changes it.** `policy/set` saves the rules, and fails when another admin
  saved first. `policy/stopAll` turns the kill switch on or off. `policy/raise` raises one
  person's budget for today (UTC). The audit records each of them. Every person can read the
  rules in force with `policy/mine`.
- **Machines that do not follow it.** When the policy sets `requireFollowing`, the control
  plane refuses to start work (a new agent, a prompt, a fork) on a machine that has not
  kept the current version. The error is `policyRefused` (-32076), with the reason `update`.

The fields are in [Policy](../reference/policy.md). Each machine enforces the rules itself,
also when it is offline; that part, the **Set by your organisation** line on each client,
the Console page and the MDM pin come in later steps of #998.

## A browser on this Mac

Agents Host's copy of the control plane has a second, smaller listener: plain HTTP on the
loopback address only, at **http://localhost:8792**. It serves the web page, which is
built into Agents Host and checked against a list of its files' hashes, and takes the
page's WebSocket. Nothing else on the network can reach it, and **Serve Agents to browsers
on this Mac** in Agents Host turns it off.

A browser that pairs there becomes a client of the **browser** kind, with a key of its own
that script can use but not read. A browser key works only on that listener, and a window's
or phone's key only on the HTTPS address, so neither can stand in for the other. Each proof
of a key is bound to the address it was made for. The listener answers only a request
addressed to `localhost` on its own port, and a WebSocket only from its own page. So a
website you visit can't use it, by DNS trickery or otherwise. The page sets no cookies and
relies on nothing the browser sends by itself.

What someone holding a browser's session could do, in brief:

- **Script running in the page**, such as a malicious extension, can do whatever the
  window can while the page is open: on a machine that includes running commands, and at the
  control plane pairing or forgetting clients and adding machines.
  The page draws nothing an agent wrote as HTML, and loads nothing from anywhere else.
  Forgetting the browser stops it at once.
- **A copy of the browser's profile on another computer** can do nothing: the listener is
  on loopback only.
- **Another account on this Mac** can reach the listener, but has no key, and a code works
  once, for five minutes.
- **A website** can do nothing: its requests are refused on their address and origin, and
  it has no key.

### With the control plane elsewhere

When the control plane runs elsewhere, this Mac's machine serves the page instead, with the same
listener: the same address checks, the same list of files and the same origin rule. The machine
can't check a browser's key, because that needs the control plane's private key, which a machine
never has. So for each page, the machine opens a socket of its own to the control plane and proves
itself there as a machine that carries a page, from its loopback listener on a given port. The
page's own exchange then runs on that socket, with the control plane, bound to
`localhost` on that port.

That is a rule of trust: the control plane takes the machine's word that the socket came in on
the machine's loopback listener. It gives a machine nothing new. A machine can carry only the sessions
of browsers that paired at its own `localhost` address, because only the browser's key can
prove itself there, and a machine already reads and answers everything its own agents do. A
relay machine, which runs no agents, can't carry a page. See `specs/1480-local-page-on-agentsd/`.

Since every client may do everything (#111), the listener's address and origin checks and
the key that can't be read are what keep a browser's session its own. Serving the page at a
public address, for a browser elsewhere, waits on issue #61.

## The window and this Mac's machine

The window on a Mac talks to that Mac's own machine over a local socket, not out to the
control plane and back. It is quicker, and when the control plane cannot be reached, the
window still works with the agents on this Mac.

The control plane is still the authority for who may connect. It tells each machine which
windows are paired, with their keys, and the machine keeps that list for when the control
plane is away. A window proves its own key to the machine, as it does to the control plane.
Forget a window, and its machine cuts it off at once, as the control plane does.

Everything else is as before. What the window does on the local path, the machine tells every
client, those through the control plane too, so every other screen sees the same thing. The
window still uses the control plane for every other machine, for pairing, and for the
control plane's own settings.

The socket is in a folder that only Agents and Agents Host can reach (their shared app
group), and is named by the control plane's key, so a second control plane on the same Mac
has a socket of its own. When it is not there, the window goes through the control plane as
before. The iPhone, the iPad and a browser always go through the control plane for now.

## Copies and the store

The control plane itself remembers little: the clients, the machines, the
codes it has handed out, and which of its copies is holding each machine's connection. That
is its **store**. It is either a folder or an S3-compatible bucket. Nothing else,
no database, is needed. Your agents and their conversations are not in it: they stay on
their machines.

A **copy** is one running control plane. Because everything a copy needs to remember is in
the store, a copy holds only live connections, and any number of copies can share one
store. Any copy will take any client or machine, and a request for a machine held by another
copy is passed across. A code shown by one copy works at any other, once.

Every copy is given the same private key, which proves to clients and machines that they have
reached your control plane and not someone else's. That key is never written to the store
in clear: whatever runs the copies hands it to each one as a secret, or a cloud machine's
KMS seals it in the store.

### Back up and restore

A copy of the store is not a backup on its own. A restore also needs the control key (or,
on a cloud machine, the KMS key that sealed it), the key that seals secrets, and the
certificate that devices are pinned to. Without the key, the restored control plane does not
start; without the certificate, every device must pair again. `agents-control backup` puts
all of them into one folder, and `agents-control restore` puts them back into a new home:
see [Back up and restore a control plane](../how-to/back-up-a-control-plane.md).

## Where to run it

There are two ordinary shapes.

**On this Mac.** Agents Host, a free download from us that is not in the App Store, runs
this Mac's machine and a single copy of the control plane, kept running by macOS with every
window closed. Its store is a folder on this Mac by default, or a bucket of your own. This
is the shape for one person at home.

The cost is that the Mac is the control plane. While it sleeps, or is away from your
network, no window or device can reach any of your agents, including those on servers.
Agents on servers keep working all the same; you just cannot see them until the Mac is
back.

**Several copies with a bucket.** The control plane also runs as a container on Linux. Run
two or more copies on hosting you rent, with one bucket for their store, behind any load
balancer that passes WebSockets through. If one copy stops, the clients and machines that were
on it reconnect to another within seconds. This is the shape for staying up while your Mac
sleeps. The copies are for staying up, not for load: the control plane is sized for one
person, with a handful of screens and up to about twenty machines.

Either way it is yours. Nothing passes through a service we run, and the control plane has
one address, a name, that every code carries.

## When the control plane is down

When no copy can be reached, no client can reach a machine on another machine. The window
says **Can't reach the control plane**, names the address it expected, and shows what it
last knew rather than an empty list. The window still works with this Mac's own machine, and
the strip says so.

Nothing stops on the machines. An agent that was working carries on and finishes. A question
it asks waits on its machine until a client is back to answer it. The tools an agent is given
talk to the machine on its own machine, never through the control plane, so they keep working
too. When a copy is back, machines and clients reconnect by themselves, and every client
catches up on what happened meanwhile.

When one copy of several stops, the connections it held move to the others. A machine is
shown offline only for as long as that takes, and a request made in the gap is answered
afterwards or refused with a reason, never lost without a word.

A machine that loses its own network keeps its agents working in the same way, and reconnects
when the network returns.

A machine that has not joined yet tries the same way. Its join code is spent only by a join
that worked, so a first try that fails, because the control plane isn't up yet or its
address doesn't resolve yet, is tried again on the same backoff, and at once on a wake or
a network change. Until it joins, Agents Host and **Settings ▸ Control plane** say
**Couldn't join the control plane**, with the reason. The address in every code is this
Mac's Bonjour name (System Settings ▸ General ▸ Sharing ▸ Local hostname), the one other
machines on the network can resolve, not its Unix host name, which a managed Mac may set
to something nothing answers for. A request for a machine that is offline is refused at once with
that reason, rather than left to time out.

## Starting machines

A machine that stops (a cloud machine turned off, a container stopped) is offline like any
other, and nothing reaches it. When it runs on a provider's workspace, the control plane can
start it again. It asks a **machine provider**, which is an MCP server, and then waits for
the machine to connect. See [Start machines from Agents](../how-to/start-machines-from-agents.md).

Providers run on the control plane, not on a machine, because the machine is what is down. Their
secrets stay in the control plane's own folder, never in its store. A machine linked to a
workspace adds three states to the usual ones: **stopped**, **starting** and **stopping**.
Every client draws them, from the same `machines/list` and `control/hostChanged` as the rest.

A prompt or a new agent for a stopped workspace's machine is **kept** by the control plane, in
its store, and the workspace is started. When the machine connects, the control plane sends each
kept request to it in order, as the client that sent it, with the same id the client would
have retried with, so it is done once. Nothing else is kept: any other request for a stopped
machine is refused, and says it is stopped.

A machine also tells the control plane, on its own channel, whether it is idle: no turns, no
questions waiting and no shells open. The control plane counts down each linked machine's
**stop when idle** from that, and stops the workspace through its provider when the time
is up. The machine's own clock isn't used.

With its idle status, a machine also sends the time and name of its next scheduled workflow. The
control plane keeps the last one on the machine's link. While the workspace is stopped, it gives
it a **wake-up call**: it starts the workspace before that time, by the last measured start
time plus 2 minutes (5 minutes before one is measured), once for each due time. The machine
connects, and its own clock fires the workflow; the control plane decides only when the
machine runs. It does not stop a machine as idle while its next workflow is due within its idle
time. While the Mac that runs the control plane sleeps, no wake-up calls are made.

For now only a control plane with one copy runs providers, as only one holds ssh tunnels.

**Write It for Me** puts an agent in the Add Provider sheet, at authoring time only. The
agent runs on the machine on the control plane's own machine, because the server and the CLI
must be read there. The control plane does every call to the server or the CLI itself, with
the secrets, and gives the agent only the results, with each secret's value replaced by its
name. The agent has no tools of its runtime's own and is in no list. Start and Stop never
call an agent: they use the map that was kept.

## When the store is down

If the copies are running but cannot reach their store, the live connections carry on:
you can still follow, answer and start agents. What cannot happen is anything the control
plane must remember. Pairing or forgetting a client, adding a machine or removing one is
refused, and the window says the control plane can't reach where it keeps its records, so
nothing was changed. Nothing is ever half done.

When two copies change the same record at the same moment, for instance two windows
changing one machine's settings, one change goes through and the other is refused and asked to
try again. Neither is lost without a word.

## Why it is built this way

Before the control plane, the Mac window was special. It started the daemon on this Mac,
reached each server itself over ssh, and was the only thing allowed to do everything. The
phone reached only the Mac, through a separate bridge, and saw only the Mac's folders.
What you could reach depended on which screen you held, and pairing, permissions and
routing lived in three places.

It also meant none of the apps could be in the App Store. An App Store app runs in a
sandbox: it may not start helpers of its own, keep programs running in the background, run
ssh or git, or read folders you did not hand it. The Mac window did all of those.

Putting one service in the middle fixes both. The apps become screens and nothing else, so
they fit in the sandbox. Everything that needs a real machine happens on a machine: agents,
terminals, files, git, installing runtimes, signing them in. And because machines connect out
and clients connect in, a server behind a home router or a firewall joins without any port
being opened to it.

The control plane speaks ordinary HTTPS and WebSockets, so any load balancer or TLS proxy
can sit in front of it. Clients and machines prove who they are by signing with keys of their
own when they connect. Its store is a folder or a bucket, because those are what anyone can
run, and a bucket is what lets several copies share one memory without one of them being
special.

## Related

- [Set up Agents on this Mac](../how-to/set-up-on-this-mac.md).
- [Run the control plane as several copies](../how-to/run-several-copies.md).
- [Connect a window or phone](../how-to/connect-a-window-or-phone.md).
- [The window and the machine](window-and-daemon.md).
- [How the phone and iPad reach your agents](phone-and-ipad.md).
- [Use Agents in a browser](../how-to/use-agents-in-a-browser.md).
- [Machine providers](../reference/machine-providers.md).
