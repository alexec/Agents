---
diataxis: explanation
description: How the iPhone and iPad apps reach your Mac, what they can and cannot do, and what that means for security today.
devices: [mac, iphone, ipad]
---

# How the phone and iPad reach the Mac

The iPhone and iPad apps are windows onto your Mac, like the Mac window itself. Nothing
runs on them. This page explains how they reach the Mac, what they can do there, and what
you should know about the connection as it is today.

## The work stays on the Mac

Your agents belong to the daemon on your Mac (see
[The window and the daemon](window-and-daemon.md)). The phone and the iPad talk to that
same daemon. They read the same conversations, and what you do on them happens on the Mac.
An agent you start from your phone runs in the project's folder on the Mac, with the Mac's
runtimes, and shows up on the Mac as if you had started it there.

That is why the Mac needs to be awake and reachable for the phone to be of use, and why
nothing is lost if your phone runs out of battery.

## Two ways to reach you

There are two separate paths from the Mac to your devices.

The first is a direct connection on your local network. A small helper on the Mac, the
bridge, offers the daemon to devices on the same network. The phone and iPad find the Mac
by themselves, without you typing an address. Everything you see and do in the iPhone and
iPad apps goes over this connection.

The second is notifications. When an agent needs you and you are not at the Mac, the Mac
sends a short notice to your device through your own iCloud account. It is sealed so that
only that one device can read it. If you are at the Mac, the Mac tells you itself and your
devices stay quiet. If you are away, the device you used most recently is told, and the
iPhone when it cannot tell which. When the question is answered, or goes away, the notice
is taken down.

## What you can do from the phone and iPad

On the direct connection, the iPhone and iPad can:

- see every project on the Mac and its agents, grouped the same way as on the Mac,
- read a conversation as it happens, and answer permission requests and questions,
- send a prompt, attach a file or a picture, dictate, and change the agent's mode or model,
- start a new agent, in the project folder or in a worktree, and remove a worktree,
- stop or archive an agent,
- see a project's workflows, run one now, and archive or restore one,
- open the agent's files, follow a live page as the agent writes it and type on it, and
  use a terminal in the agent's folder,
- see what an agent holds or waits for (see [Leases on shared resources](leases.md)), and
  what has been spent.

## What stays on the Mac

Some things are only on the Mac:

- the browser pane,
- the Resources page, where you end a lease,
- adding, archiving and renaming projects,
- signing a runtime in, and changing settings such as spending limits,
- servers: your devices see only the projects on your Mac, not projects on a Linux server.

## The connection today

Be aware of how the direct connection works today.

The bridge is not started by the app. You start it by hand on the Mac, and it runs until
you stop it. While it is not running, your devices cannot reach the Mac, and notifications
that were due wait on the Mac until it is.

The direct connection has no pairing and no encryption. Any device on the same local
network that finds the bridge can see and drive your agents. Run it only on a network you
trust, such as your home network, and stop it when you do not need it.

It also only works on the same network. When your phone is somewhere else, it says it
cannot reach your Mac, and shows what it last knew, dimmed, without offering any action.
Notifications still arrive, because they go through iCloud, but to answer one you need to
be back on the Mac's network.

Notifications are the part that is protected today. Each one is sealed to the device it is
for before it leaves the Mac, and travels through your own iCloud account, not through a
server of ours.

## Related

- [How-to guides](../how-to/index.md), for setting up the phone and answering questions
  from it.
- [Reference](../reference/index.md), for what each status means on every device.
