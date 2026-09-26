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

## Three ways to reach you

There are three separate paths from the Mac to your devices.

The first is a direct connection on your local network. A small helper on the Mac, the
bridge, offers the daemon to devices on the same network. The phone and iPad find the Mac
by themselves, without you typing an address. At home, everything you see and do in the
iPhone and iPad apps goes over this connection, and it is instant.

The second is the relay, for when your device is somewhere else. The same requests and
updates go through your own iCloud account instead, each one sealed so that only your Mac
and that one device can read it. Nothing passes through a server of ours. The device
switches between the two by itself: leave the house and a line at the top says **Away —
slower, through iCloud**; come back and it goes. The relay is slower, about two or three
seconds for each answer, which is why a few things wait until you are home (see below).

The third is notifications. When an agent needs you and you are not at the Mac, the Mac
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

Be aware of how the connections work today.

The bridge is not started by the app. You start it by hand on the Mac, and it runs until
you stop it. While it is not running, your devices cannot reach the Mac from anywhere, and
notifications that were due wait on the Mac until it is.

**Pairing happens at home.** The first time a device connects on the Mac's network, the Mac
hands it the key the relay is sealed with. After that, the device can reach the Mac from
anywhere. A device that has never been on the Mac's network says **Open Agents once on your
Mac's Wi-Fi**, and sends nothing through iCloud. The Mac and the device must be signed in to
the same iCloud account.

**Away, the everyday things work**: your projects and agents, reading a conversation and
following it as it grows, sending prompts, answering questions and permissions, starting,
stopping and archiving agents, changing an agent's mode or model, and the events list. The
terminal, the live page, files and attaching pictures say **Needs the same network as your
Mac**, because they send too much, too often, for iCloud. They open by themselves when you
are back on the Mac's Wi‑Fi.

**Forgetting a device.** In Settings ▸ Devices on the Mac, **Forget…** cuts a device off from
the relay at once, and deletes what was waiting for it in iCloud. It pairs again the next
time it is on the Mac's network.

The direct connection has no pairing and no encryption. Any device on the same local
network that finds the bridge can see and drive your agents. Run it only on a network you
trust, such as your home network, and stop it when you do not need it. The relay and
notifications are the parts that are sealed: each message is sealed to the one device or
Mac it is for before it leaves, and travels through your own iCloud account.

## Related

- [How-to guides](../how-to/index.md), for setting up the phone and answering questions
  from it.
- [Reference](../reference/index.md), for what each status means on every device.
