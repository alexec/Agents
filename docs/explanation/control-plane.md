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
                      │   sandboxed, runs nothing          grant: device           │
                      │   grant: operator                                          │
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
│   └──────┬───────┘                 └──────┬───────┘     - checks the grant on       │
│          └──────────────┬─────────────────┘               every call                │
│                         ▼                                                           │
│              ┌─────────────────────┐   who is paired, with which grant; which       │
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

## Operators and devices

Each client is paired once, with a code the control plane shows, and is given a grant that
says what it may do.

- An **operator** may do everything: start and stop agents on any host, sign runtimes in,
  add and remove hosts, and pair or forget other clients. A window on a Mac is usually an
  operator.
- A **device** may do what a phone does: follow and answer agents, start and stop them,
  and use their files and terminals. It cannot sign runtimes in, browse a host's folders,
  add or rename projects, or change who may do what. An iPhone or iPad is usually a device.

The control plane checks the grant before a request reaches a host, and the host checks it
again. You can change a grant, or forget a client, in **Settings ▸ Control plane ▸
Clients**; forgetting cuts the client off at once. The app will not let you demote or
forget the last operator, because nothing could then undo it.

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
  browser's grant allows while the page is open. On a host that includes running commands.
  The page draws nothing an agent wrote as HTML, and loads nothing from anywhere else.
  Forgetting the browser stops it at once.
- **A copy of the browser's profile on another computer** can do nothing: the listener is
  on loopback only.
- **Another account on this Mac** can reach the listener, but has no key, and a code works
  once, for five minutes.
- **A website** can do nothing: its requests are refused on their address and origin, and
  it has no key.

This is why a browser is paired as a device unless you choose otherwise. Serving the page
at a public address, for a browser elsewhere, waits on issue #61.

## Copies and the store

The control plane itself remembers little: the clients and their grants, the hosts, the
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
plane must remember. Pairing a client, changing a grant, adding a host or removing one is
refused, and the window says the control plane can't reach where it keeps its records, so
nothing was changed. Nothing is ever half done.

When two copies change the same record at the same moment, for instance two windows
changing one client's grant, one change goes through and the other is refused and asked to
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
