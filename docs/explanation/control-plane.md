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

## Hosts, clients and the control plane

A **host** is a machine that runs agents. Your Mac is one, once Agents Host is installed on
it. A Linux server is another, and so is a second Mac. A host owns its agents: it starts
their runtimes, holds their conversations and keeps their records on its own disk.

A **client** is a screen: the Agents window on a Mac, Agents on an iPhone or iPad, or a
browser on the Mac that runs the control plane. A client runs nothing. It shows what the hosts hold and passes on what you type and click.

The **control plane** sits between them. Every host and every client connects to it, and
it sends each request to the host it concerns and each update to the clients that should
hear it. A client never connects to a host directly, and a host never needs to be reached:
it connects out, like a client does.

So a server you add once is seen by every window and phone, with nothing to set up on each
one, and who may do what is decided in one place.

Every arrow points the way its connection is made. Everything connects out to the control
plane, and nothing connects in to a host.

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
│   │              │   to each other │              │       client and host pair      │
│   └──────┬───────┘                 └──────┬───────┘     - checks each client's      │
│          └──────────────┬─────────────────┘               key, and nothing else     │
│                         ▼                                                           │
│              ┌─────────────────────┐   who is paired, and of what kind; which       │
│              │ store: folder or S3 │   hosts there are; codes not yet used;         │
│              └─────────────────────┘   settings                                     │
└──────────────▲───────────────────────────────▲──────────────────────────────▲───────┘
               │ connects out, joined          │ connects out                 │ connects out
               │ by a host code                │                              │
┌──────────────┴────────────┐   ┌──────────────┴────────────┐   ┌─────────────┴──────────────┐
│ HOST: this Mac            │   │ HOST: another Mac         │   │ HOST: a Linux server       │
│ Agents Host               │   │ Agents Host,              │   │ agentsd, installed over    │
│  ├ agentsd                │   │ Join one elsewhere        │   │ ssh or by one command      │
│  ├ agents-control, if the │   │  └ agentsd only           │   │                            │
│  │ control plane runs here│   │                           │   │                            │
│  └ agents-relay, optional │   │                           │   │                            │
│ projects, agents,         │   │ projects, agents,         │   │ projects, agents,          │
│ runtimes, files, terminals│   │ runtimes                  │   │ runtimes                   │
└──────────────┬────────────┘   └───────────────────────────┘   └────────────────────────────┘
               │ agents-relay, optional (not in this build yet)
               ▼
     your iCloud mailbox ──► iPhone and iPad away from home, and notifications
```

Your agents, their conversations, files and terminals, and the runtimes' sign-ins stay on
the host they belong to. The control plane's store only remembers who is paired and which
hosts there are.

## One grant for every client

Each client is paired once, with a code the control plane shows, and may then do
everything the Mac's own window may: start and stop agents on any host, open terminals,
sign runtimes in, add and remove hosts and projects, set helper limits, and pair or forget
other clients. A window, an iPhone, an iPad and a browser are all the same in this.

There used to be two grants, **operator** and **device**, and a phone was a device. That
was retired on 2026-10-02 (#111): a device could already start agents and open terminals
on any host, so it could run any command there, and the split protected the hosts very
little while asking a question on every pairing sheet. What it cost, accepted: a lost
phone or a hijacked browser tab can pair more clients, forget yours, add hosts or sign
runtimes in, until you forget it from another screen.

What still tells clients apart is who they are, not what they may do. A phone's or a
browser's connection to a host is bound to that one client: it reports where you are as
itself, and can't speak as another. An agent's own connection to its host still reaches
only its tools, and anything else on the Mac reaches nothing.

You can forget a client in **Settings ▸ Control plane ▸ Clients**; forgetting cuts it off at
once, at home and away. Any client may be forgotten, the last one too: Agents Host, on the
control plane's own Mac, can always make a new code.

Older builds keep working. A record, a code or a channel still carries the word `grant`,
always `operator`, which an older copy, host, Remote or web page reads as everything; a
record written before as `device` is read as a full client. An older window that tries to
change a grant is told there is nothing to change.

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
  window can while the page is open: on a host that includes running commands, and at the
  control plane pairing or forgetting clients and adding hosts.
  The page draws nothing an agent wrote as HTML, and loads nothing from anywhere else.
  Forgetting the browser stops it at once.
- **A copy of the browser's profile on another computer** can do nothing: the listener is
  on loopback only.
- **Another account on this Mac** can reach the listener, but has no key, and a code works
  once, for five minutes.
- **A website** can do nothing: its requests are refused on their address and origin, and
  it has no key.

Since every client may do everything (#111), the listener's address and origin checks and
the key that can't be read are what keep a browser's session its own. Serving the page at a
public address, for a browser elsewhere, waits on issue #61.

## Copies and the store

The control plane itself remembers little: the clients, the hosts, the
codes it has handed out, and which of its copies is holding each host's connection. That
is its **store**. It is either a folder on disk or an S3-compatible bucket. Nothing else,
no database, is needed. Your agents and their conversations are not in it: they stay on
their hosts.

A **copy** is one running control plane. Because everything a copy needs to remember is in
the store, a copy holds only live connections, and any number of copies can share one
store. Any copy will take any client or host, and a request for a host held by another
copy is passed across. A code shown by one copy works at any other, once.

Every copy is given the same private key, which proves to clients and hosts that they have
reached your control plane and not someone else's. That key is never written to the store;
whatever runs the copies hands it to each one as a secret.

## Where to run it

There are two ordinary shapes.

**On this Mac.** Agents Host, a free download from us that is not in the App Store, runs
this Mac's host and a single copy of the control plane, kept running by macOS with every
window closed. Its store is a folder on this Mac by default, or a bucket of your own. This
is the shape for one person at home.

The cost is that the Mac is the control plane. While it sleeps, or is away from your
network, no window or device can reach any of your agents, including those on servers.
Agents on servers keep working all the same; you just cannot see them until the Mac is
back.

**Several copies with a bucket.** The control plane also runs as a container on Linux. Run
two or more copies on hosting you rent, with one bucket for their store, behind any load
balancer that passes WebSockets through. If one copy stops, the clients and hosts that were
on it reconnect to another within seconds. This is the shape for staying up while your Mac
sleeps. The copies are for staying up, not for load: the control plane is sized for one
person, with a handful of screens and up to about twenty hosts.

Either way it is yours. Nothing passes through a service we run, and the control plane has
one address, a name, that every code carries.

## When the control plane is down

When no copy can be reached, no client can reach any host. The window says **Can't reach
the control plane**, names the address it expected, and shows what it last knew rather
than an empty list.

Nothing stops on the hosts. An agent that was working carries on and finishes. A question
it asks waits on its host until a client is back to answer it. The tools an agent is given
talk to the host on its own machine, never through the control plane, so they keep working
too. When a copy is back, hosts and clients reconnect by themselves, and every client
catches up on what happened meanwhile.

When one copy of several stops, the connections it held move to the others. A host is
shown offline only for as long as that takes, and a request made in the gap is answered
afterwards or refused with a reason, never lost without a word.

A host that loses its own network keeps its agents working in the same way, and reconnects
when the network returns. A request for a host that is offline is refused at once with
that reason, rather than left to time out.

## When the store is down

If the copies are running but cannot reach their store, the live connections carry on:
you can still follow, answer and start agents. What cannot happen is anything the control
plane must remember. Pairing or forgetting a client, adding a host or removing one is
refused, and the window says the control plane can't reach where it keeps its records, so
nothing was changed. Nothing is ever half done.

When two copies change the same record at the same moment, for instance two windows
changing one host's settings, one change goes through and the other is refused and asked to
try again. Neither is lost without a word.

## Why it is built this way

Before the control plane, the Mac window was special. It started the daemon on this Mac,
reached each server itself over ssh, and was the only thing allowed to do everything. The
phone reached only the Mac, through a separate bridge, and saw only the Mac's projects.
What you could reach depended on which screen you held, and pairing, permissions and
routing lived in three places.

It also meant none of the apps could be in the App Store. An App Store app runs in a
sandbox: it may not start helpers of its own, keep programs running in the background, run
ssh or git, or read folders you did not hand it. The Mac window did all of those.

Putting one service in the middle fixes both. The apps become screens and nothing else, so
they fit in the sandbox. Everything that needs a real machine happens on a host: agents,
terminals, files, git, installing runtimes, signing them in. And because hosts connect out
and clients connect in, a server behind a home router or a firewall joins without any port
being opened to it.

The control plane speaks ordinary HTTPS and WebSockets, so any load balancer or TLS proxy
can sit in front of it. Clients and hosts prove who they are by signing with keys of their
own when they connect. Its store is a folder or a bucket, because those are what anyone can
run, and a bucket is what lets several copies share one memory without one of them being
special.

## Related

- [Set up Agents on this Mac](../how-to/set-up-on-this-mac.md).
- [Run the control plane as several copies](../how-to/run-several-copies.md).
- [Connect a window or phone](../how-to/connect-a-window-or-phone.md).
- [The window and the host](window-and-daemon.md).
- [How the phone and iPad reach your agents](phone-and-ipad.md).
- [Use Agents in a browser](../how-to/use-agents-in-a-browser.md).
