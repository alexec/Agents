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

Every lease has an end. A lease lasts 30 minutes unless the agent asks for another length,
and never more than four hours without being extended. An agent that needs longer extends
the lease before it runs out, and is warned when the end is five minutes away.

A lease does not end when the agent's turn ends. It is kept until the agent releases it,
it runs out, you end it, or the agent is stopped or archived. That way an agent can hold a
simulator across a pause without losing its place. The lease also survives the app
restarting, with the same end time.

## Waiting in line

If another agent holds the resource, the asking agent joins a line and waits. When the
lease is released or runs out, the resource goes to whoever asked first.

An agent does not have to wait with its turn open. If the lease has not come to it after
45 seconds, it is told it is still in line and can end its turn, keeping its place. When
the resource comes free, the app starts that agent again with the lease already in its
hands, and a message saying so appears in its conversation. If you have sent it something
in the meantime, the app's message waits until that turn is over.

An agent that needs two resources asks for them one at a time, always in the same order,
so that two agents cannot each hold one and wait forever for the other. If that happens
anyway, both leases still run out in time, and you can see both waits and end one of them.

## What you see

In the Mac window, the **Resources** row at the bottom of the sidebar opens a page listing
every resource, whether it is free, who holds it and since when, when the lease runs out,
and who is waiting, in order. Each agent's chat has a line saying what it holds and what
it is waiting for, and its card on the project page says the same briefly.

On iPhone and iPad, the chat and the card show the same leases and waits. The Resources
page is on the Mac only.

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
same project share one line, because they share one Mac.

## Related

- [How-to guides](../how-to/index.md), for stopping and archiving agents.
- [Reference](../reference/index.md), for the lease tools the app gives agents.
