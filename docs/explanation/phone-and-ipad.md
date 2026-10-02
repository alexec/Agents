---
diataxis: explanation
description: How the iPhone and iPad apps, and a browser on this Mac, reach your agents on every host, what they can and cannot do, and how pairing and forgetting a device work.
devices: [mac, iphone, ipad]
---

# How the phone and iPad reach your agents

The iPhone and iPad apps are windows onto your agents, like the Mac window itself. Nothing
runs on them. This page explains how they reach your agents, what they can do there, and
what you should know about the connection.

## The work stays on the hosts

Your agents belong to hosts: your Mac with Agents Host, and any server you have added (see
[The window and the host](window-and-daemon.md)). The phone and the iPad connect to your
control plane, as the Mac window does, and reach every host through it (see
[The control plane](control-plane.md)). They read the same conversations, and what you do
on them happens on the host. An agent you start from your phone runs in the project's
folder on that project's host, with that host's runtimes, and shows up in every window as
if you had started it there.

That is why the phone needs the control plane, and the host, to be up for it to be of use,
and why nothing is lost if your phone runs out of battery.

## Every host

A paired iPhone or iPad sees the projects on every host, each under its host's heading, as
the Mac window does. A server you add once appears on your devices within a few seconds,
with nothing to do on them.

## Pairing

A device is paired once, with a code your control plane shows. There are two places to
get one:

- In the Mac window, **Settings ▸ Control plane ▸ Clients ▸ Pair a Device…** shows a code
  to scan with Agents on the device.
- In Agents Host on the Mac that runs the control plane, **Pair a Window or Phone…** with
  **An iPhone or iPad** chosen shows the code as text, to copy and paste into the device.

A code works once, for five minutes. The device keeps a key of its own, and proves it holds
that key each time it connects. A device that has not paired says **Connect to your
agents**, and sends nothing.

A paired device may do everything the Mac's window may, on every host (#111). There used
to be a **device** grant that kept a phone to the Remote's own screens; it protected the
hosts little, since a phone could already run commands in a terminal, and was retired. See
[The control plane](control-plane.md#one-grant-for-every-client) for what that risks.

## What you can do from the phone and iPad

The iPhone and iPad have screens for these, on any host:

- see every project and its agents, grouped the same way as on the Mac,
- read a conversation as it happens, and answer permission requests and questions,
- send a prompt, attach a file or a picture, dictate, and change the agent's mode or model,
- start a new agent, in the project folder or in a worktree, and remove a worktree,
- stop or archive an agent,
- see a project's workflows, run one now, and archive or restore one,
- open the agent's files, follow a live page as the agent writes it and type on it, and
  use a terminal in the agent's folder,
- see what an agent holds or waits for (see [Leases on shared resources](leases.md)), and
  what has been spent.

## The widget does not reach your agents at all

The Home-screen widget is the exception, and worth knowing about. It is a small program
that iOS loads only when it is about to draw one, and throws away the moment it is done, so
it is never given a connection to anything. What it draws is a small file your app writes
whenever the number changes, which the widget reads and shows.

In practice that means the widget is the one thing on the device that works with the app
shut: it is showing you what the app last knew, not what your hosts know now. When the app
is shut and something starts waiting, the widget keeps showing the number it had, and
says how long ago it was updated. Tapping it opens the app, which catches up.

## What has no screen on the phone yet

Nothing is refused to a device any more, but some things have screens only in the Mac
window so far:

- adding, archiving and renaming projects, and browsing a host's folders,
- signing a runtime in, lending a credential, and changing settings such as spending
  limits and helper limits,
- adding and removing hosts, and pairing or forgetting clients.

The browser pane and the Resources page, where you end a lease, are on the Mac only.

## At home and away

At home, the device connects to the control plane's address, the one its code carried,
over HTTPS. It checks the control plane's certificate against the one named in the code,
so nothing else on the network can stand in for it.

Away from home, the device connects to that same address if it can reach it, which it can
when the control plane runs on hosting of your own with a public name. If it cannot, for
instance because the control plane is on your Mac at home, it can go through the relay
instead: the same requests and updates pass through your own iCloud account, each one
sealed so that only your control plane and that one device can read it. Nothing passes
through a server of ours. A device on the relay says **Away — slower, through iCloud**.
The relay is slower, about two or three seconds for each answer, so the terminal, the live
page, files and attaching pictures wait until the device can reach the address again.
Through the relay, a device reaches this Mac's host; your other hosts wait until it can
reach the control plane's address again.

Notifications take the same path. When an agent on any host needs you, a short notice is
sealed to your device and posted to your own iCloud account. When the question is
answered, or goes away, the notice is taken down.

The relay and notifications are run by a Mac host, because they need your iCloud account.
In this build, Agents Host cannot switch them on yet: its **Relay for my devices** row says
**Not in this build yet**. Until it can, a device reaches your agents only where it can
reach the control plane's address, and gets no notifications. A set-up with no Mac host at
all never has them.

## Forgetting a device

In **Settings ▸ Control plane ▸ Clients** on the Mac, **Forget…** cuts a device off at
once, directly and through the relay, and on every copy of the control plane. Its next
attempt to connect is refused. To use it again, pair it again with a new code. Any client
may be forgotten from any other, the last one too; Agents Host can always make a new code.

## A browser on this Mac

A browser is one more client. Agents Host serves Agents as a web page at
**http://localhost:8792**, and a browser on the same Mac pairs with a code, as a phone
does, from **Pair a Browser…**. It may do everything the window may; its page shows what
the phone does, except that it has no terminal, no dictation and no notifications.

The browser keeps a key that can't be copied out of it, made when it pairs and kept in
that browser's storage for the page. Clearing the site's data loses it, and the browser
pairs again.

It works only on this Mac for now. The page is served on the loopback address, which
nothing else on the network can reach, so a copy of the browser's profile on another
computer can do nothing with the key. Serving the page at a public address, so a browser
elsewhere can use it, waits on issue #61. See
[Use Agents in a browser](../how-to/use-agents-in-a-browser.md).

## Devices paired before the control plane

An iPhone or iPad paired with the earlier Agents app on your Mac keeps working after you
move that set-up across to a control plane, without pairing again. The next time it
connects the old way, it is told where the control plane is, and connects there from then
on. See [Move an existing set-up across](../how-to/move-an-existing-set-up.md).

## Related

- [Connect a window or phone](../how-to/connect-a-window-or-phone.md), for pairing.
- [Use Agents in a browser](../how-to/use-agents-in-a-browser.md), for the web page.
- [Answer a question or a permission request](../how-to/answer-a-question.md), for the
  card on every device.
- [See what needs you from your Home screen](../how-to/see-what-needs-you-from-your-home-screen.md),
  for putting that count on the Home screen.
- [Statuses and groups](../reference/statuses.md), for what each line at the top of the
  phone means.
