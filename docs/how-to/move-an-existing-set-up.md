---
diataxis: how-to
devices: [mac, iphone, ipad, server]
description: Move the agents, paired devices and servers of the earlier Agents app on this Mac to a control plane, once, keeping everything.
---

# Move an existing set-up across

The earlier Agents app ran its own daemon on this Mac, paired your iPhone and iPad itself,
and reached your servers over ssh. Agents Host moves all of that to a control plane on this
Mac, once, when you choose. Your agents and their conversations stay where they are, your
devices keep working without pairing again, and your servers become hosts.

## Before you start

- No agent in the middle of a turn. The move refuses to start while one is working.
- Your iPhone and iPad at hand, and still able to reach this Mac the earlier way (the
  earlier app's bridge running), so that each can be told where the control plane is.
- ssh from this Mac to each server still working, as the earlier app used it.

## Steps

### Move

1. Install Agents Host and open it. At the top of its window it says **You have agents from
   the earlier Agents app on this Mac.** Click **Move Across…**.
2. The sheet, **Move to a control plane on this Mac**, lists what is kept: your agents and
   their conversations, which stay on this Mac as this Mac's host; each paired device,
   which keeps working without pairing again; and each server, which is added as a host.
   Click **Move Across**.

   It steps through **Letting the earlier app's agents go…**, **Starting the control plane
   and this Mac's host…**, **Moving your devices…**, and **Adding devbox as a host…** for
   each server. It ends with **Moved. Your devices are told where the control plane is the
   next time they connect.**, and a line for each server.
3. Click **Done**.

Nothing is copied. Agents Host's host takes over the earlier app's folder where it is, and
the control plane's store starts on this Mac. To keep it in a bucket instead, see
[Set up Agents on this Mac](set-up-on-this-mac.md#keep-the-store-in-a-bucket-instead).

### A server that could not be reached

A server joins over your own ssh from this Mac, as the earlier app reached it. If it could
not be reached, the sheet says **devbox couldn't be reached over ssh**, with the reason, and
shows a command. Run that command on the server, as the user your agents run as, and it
joins. If the command has run out, add the server afresh; see
[Add a server](add-a-server.md).

### Pair the window

1. Open Agents, the window. It says **Agents Host is running on this Mac**. Click
   **Pair**.
2. In Agents Host, click **Copy**. In the window, paste the code under **CODE** and click
   **Connect**.

   Every agent is listed, with its history, under **THIS MAC**, and each server under its
   own heading.

### Bring your iPhone and iPad across

1. On each iPhone and iPad, at home, open Agents.

   It connects the earlier way once, is told where the control plane is, and connects
   there from then on, with the key it paired with. It now sees every host.

A device moved across may do everything a window may, on your servers too, as every paired
client may; see [Connect a window or phone](connect-a-window-or-phone.md).

## If it doesn't work

If the move cannot go on, the sheet says **Nothing has changed:** and why. Fix the cause,
then click **Try Again**.

- **an agent is working. Let its turn finish, then try again.** Wait for the turn to end,
  or stop the agent in the earlier app.
- **the earlier Agents app's daemon didn't stop. Quit Agents, then try again.** Quit the
  earlier app, then click **Try Again**.

## What to know

- The move happens once. Afterwards Agents Host no longer offers it.
- If the earlier app had no paired devices and no servers, there is nothing to move:
  quit the earlier app, then choose **Run It Here** in Agents Host, and this Mac's host
  takes over its agents where they are.

## Related

- [The window and the host](../explanation/window-and-daemon.md).
- [The control plane](../explanation/control-plane.md).
