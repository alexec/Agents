---
diataxis: how-to
devices: [mac, iphone, ipad, server]
description: Bring the agents of the earlier Agents app on this Mac to Agents, pair your devices again, and add your servers as machines.
---

# Move an existing set-up across

The earlier Agents app ran its own daemon on this Mac, paired your iPhone and iPad itself,
and reached your servers over ssh. Agents now has a control plane and runs this Mac's host
(`agentsd`) for you. When you open it, this Mac's host takes over the earlier app's agents
where they are, so your agents and their conversations stay. Your devices pair again, and
your servers join as machines.

Agents no longer has a **Move Across…** step that moves devices and servers for you
(#4227). Do the steps below instead.

To move a control plane that already runs on this Mac to a server, see
[Move the control plane from your Mac](run-the-control-plane-in-the-cloud.md#move-the-control-plane-from-your-mac).

## Before you start

- No agent in the middle of a turn.
- Your iPhone and iPad at hand.
- ssh from this Mac to each server still works.

## Steps

### Start Agents

1. Quit the earlier Agents app, so that its daemon stops.
2. Install Agents and open it. See [Set up Agents on this Mac](set-up-on-this-mac.md).

   Agents sets up a control plane and this Mac's host, and the window pairs itself. This
   Mac's host uses the earlier app's folder where it is, and copies nothing. Every agent is
   listed with its history, under this Mac in the folders list.

### Pair your iPhone and iPad again

A device that the earlier app paired does not know the new control plane. Pair each one
again with a code. See
[Connect a window or phone](connect-a-window-or-phone.md#connect-an-iphone-or-ipad).

### Add your servers

Each server joins the control plane as a machine. Add it with a command that you run on
the server, or over your own ssh from this Mac. See [Add a machine](add-a-machine.md).

## Related

- [The window and the host](../explanation/window-and-daemon.md).
- [The control plane](../explanation/control-plane.md).
