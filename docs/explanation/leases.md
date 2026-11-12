---
diataxis: explanation
description: Why only one agent at a time uses the screen, a browser or a simulator, how the others wait in line, and what you can end.
devices: [mac, iphone, ipad]
---

# Leases on shared resources

Several agents can work on your Mac at once, and some things on it can only be used by
one of them at a time: the screen, with its mouse, keyboard and front window; a browser; a
simulator. A lease is how agents take turns with those things. This page explains why
leases exist, how waiting works, and what you can do about them.

## Why agents need to take turns

Two agents driving the same browser, booting the same simulator, or clicking on the same
screen get in each other's way. What goes wrong is rarely a clean error. It is a
screenshot of the wrong window, a click that lands in the other agent's app, or a test
that fails for a reason nobody can see afterwards. Without leases, each agent finds out
about the other by colliding with it, and you find out by reading two conversations side
by side.

A lease lets an agent say "I am using this" before it starts, so every other agent, and
you, can see it.

## Taking and giving back a lease

An agent asks the app for a lease on a resource by name, uses it, and releases it when it
is done. If nobody holds it, the agent gets it at once and is told when the lease runs out.

The app knows the resources on your Mac: each simulator, each installed browser, and the
screen. An agent can list them and pick one by its name, so two agents asking for the same
thing always ask for it the same way. An agent can also lease a name of its own for
something the app does not know about, such as a network port.

Every machine also offers `browser:agents`, **This machine's browser** (#3533): one
Chromium that the host downloads on first use, runs with no window and a kept profile, so
sign-ins carry over from one session to the next, and stops after 15 minutes with no use
and no lease. One agent drives it at a time, through the `browser_*` tools (#3534): the
first call takes the lease, and the agent's turn ending lets it go.
You see it in the inspector's **Agent Browser** pane, or the web page's **Agent Browser**
tab (#3528): its newest tab, live, while the pane is open. You can click, scroll, type
and paste in it at any time, and an address typed in its bar starts it.

Every machine also offers `capacity`, **Capacity of this Mac** (#4579). Agents lease it
before heavy work that no declared resource names: a long test suite, a Chromium, a
simulator, a script that builds. It has no count. It follows the machine's level (ok,
near or full, from load per core and memory pressure; #4578, #4583): a lease is granted
at ok and goes in line at near and full. A resource named `build` follows the level in
the same way, as well as its count. So an agent that leases `build` needs nothing more.

- While the machine is near or full, a new `capacity` or `build` lease goes in line,
  also when a place is free. The reply says why: "This Mac is near capacity (load 2.4
  per core). You are 1st in line." The agent ends its turn, and `lease.granted` starts
  it again.
- The agents that hold a lease keep it, and can extend it.
- When the level is ok again, the line gets one grant for each look at the machine
  (each 15 seconds), the oldest first. Thus a burst does not make the machine full again
  at once.
- The person's booking, the browser, the screen and the simulators are not compute.
  They do not wait for the machine.

The screen lease is now actually acquired by a shipped tool (#3004): `drive_screen` takes
it the first time an agent drives an app through its own screen, mouse and keyboard, and
lets it go when the agent's turn ends or you press **Stop**.

Every lease has an end. A lease lasts 30 minutes unless the agent asks for another length,
and never more than four hours without being extended. An agent that needs longer extends
the lease before it runs out, and is warned when the end is five minutes away.

A lease does not end when the agent's turn ends. It is kept until the agent releases it,
it runs out, you end it, or the agent is stopped or archived. That way an agent can hold a
simulator across a pause without losing its place. The lease also survives the app
restarting, with the same end time.

## Declared resources, and more than one holder

Some things agents should take turns with are not on the screen at all. A Mac can only
take so many builds at once, and a test database can only be reset by one agent at a
time. You can declare a resource like that in **Settings ▸ Resources**, with a description
of when to take it, for example **build**: "Lease before any xcodebuild, swift build,
swift test, scripts/web.sh build or ship.sh; release as soon as it ends." Agents see
declared resources in `list_resources` and in their briefing, even while nobody holds them,
and are told to lease one whenever its description applies.

A declared resource can allow more than one holder: "build: 2 at once" lets two agents
compile while the rest wait in line. Up to that many agents hold it together; the next one
waits, and gets the first place to come free. Any other resource has one holder.

## Waiting in line

If another agent holds the resource, the asking agent joins a line and waits. When the
lease is released or runs out, the resource goes to whoever asked first.

An agent does not wait with its turn open. The app tells it its place in line at once, and
that it will get a `lease.granted` event when the resource is its (#2361). Its place in line
is a wait for that event, the same wait that `wait_for_event` makes, so the agent ends its
turn. When the resource comes free, the event starts the agent again with the lease already
in its hands. If you have sent it something in the meantime, the event's message waits until
that turn is over.

The wait shows as the wait card at the end of the agent's chat: "Waiting for build · held by
“Fix login” until 14:12 · 2nd in line". **End Wait** on the card, or `cancel_wait`, takes
the agent out of the line. If the agent waits for something else instead, it keeps its place,
and the app starts it again when its turn comes. The line and the wait both outlive a restart
of Agents.

An agent that needs two resources asks for them one at a time, always in the same order,
so that two agents cannot each hold one and wait forever for the other. If that happens
anyway, both leases still run out in time, and you can see both waits and end one of them.

## What you see

In the Mac window, the **Resources** row at the bottom of the sidebar opens a page listing
every resource, whether it is free, who holds it and since when, when the lease runs out,
and who is waiting, in order. At the end of each agent's chat, with the line that says it
is working, a line says what it holds and what it is waiting for. Click it to open
**Resources** at that resource. The agent's card on the folder page says the same briefly.

On iPhone and iPad, the chat and the card show the same leases and waits. Tap the line to
open **Resources** under **Activity**, which lists the declared resources and anything
held, read-only. On the web page the line opens **Resources**, which lists them under each
host. Declaring, and ending leases, are on the Mac.

## What you can end

You can end any agent's lease from the Resources page on the Mac. The resource goes to the
next agent in line at once. The agent that lost it is not interrupted: it is told you
ended its lease the next time it uses a lease tool. You can also take an agent out of a
line, which is the same as the agent giving up its place.

You cannot take a lease yourself. Only agents hold leases. If you want to use the screen
or a browser while agents are working, end their leases, or stop the agents.

## What a lease is not

A lease is an agreement between agents, not a lock on the device. Nothing stops an agent
that has not asked, or you, from using the screen or a simulator. The app's own agents are
asked, in their briefing, to lease these things before they use them.

Leases belong to one daemon. A scratch copy of the app running on a folder of its own has
leases of its own, not shared with your everyday app. Agents in different worktrees of the
same folder share one line, because they share one Mac.

## Related

- [Settings and the Resources page](../reference/settings.md), for where the Resources
  page lives and what it shows.
- [Tools the app gives agents](../reference/agent-tools.md), for the lease tools.
- [Stop and archive agents](../how-to/archive-and-stop.md), when you want an
  agent out of the line without ending its lease first.
