---
diataxis: how-to
devices: [mac]
description: Install Agents Host, run your agents and the control plane on this Mac, and pair the Agents window with it.
---

# Set up Agents on this Mac

The Agents window runs nothing itself. Your agents run on a host, and every window and
phone reaches them through a control plane you own (see
[The control plane](../explanation/control-plane.md)). The quickest way to have both is on
this Mac, with **Agents Host**.

## Before you start

- Agents, the window, on this Mac.
- Agents Host, a free download from us. It is not in the App Store, because it runs
  programs for your agents.

## Steps

### Run the control plane here

1. Open Agents. With no control plane set up, it asks **Where should your agents run?**
2. Under **Set one up on this Mac**, click **Get Agents Host…**. Download and install
   Agents Host, then open it. It lives in the menu bar; its window opens the
   first time.

   The release has a `.dmg` and a `.zip` of the same app. Neither needs admin rights.
   Drag the app into `~/Applications`, the Applications folder in your home folder,
   which you can always write to. `/Applications` asks for an admin's password. If
   your Mac won't open a disk image, a company policy for example, download the
   `.zip` instead, double-click it, and move the app it makes into `~/Applications`.

   In `~/Applications`, Agents Host updates itself to the release your control plane
   runs, with no admin password (#2178). It restarts only when no agent is in a turn.
   **Settings ▸ Machines ▸ This Mac ▸ Updates** in the window shows where the update is,
   and turns it off.
3. Agents Host asks **Where should this Mac's agents report?** Under **Run the control
   plane here**, click **Run It Here**.

   Within a few seconds **This Mac** says **Running your agents**, and under **CONTROL
   PLANE** it says **Running at** and the control plane's address, such as
   `https://my-mac.local:8791`. Both keep running with every window closed, and start
   again when you log in.

### Pair the window

1. Back in Agents, the window now says **Agents Host is running on this Mac**. Click
   **Pair**.

   Agents Host shows **Pair a Window or Phone**, with **A window on a Mac** chosen and a
   code under it. The window opens **Connect to a control plane**.
2. In Agents Host, click **Copy**.
3. In the window, paste the code under **CODE** and click **Connect**.

   The window is paired, may do everything, and shows this Mac under
   **THIS MAC** in the folders list. Add a folder to start; see
   [Add a folder](add-a-folder.md).

The code works once, for five minutes. If it runs out, close the sheet and click **Pair**
again. You can also open the sheet from the Agents Host menu bar item, with **Pair a
Window or Phone…**.

## What to know

- The control plane keeps what it remembers (paired windows and devices, and your
  machines) in a folder on this Mac. To keep it in the cloud, run the control plane there:
  see [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md).

- While this Mac sleeps, or is off your network, no window or device can reach any of
  your agents, including agents on servers. They keep working, and you see them again when
  the Mac is back. To avoid that, run the control plane elsewhere; see
  [Run the control plane as several copies](run-several-copies.md).
- Quitting Agents Host from the menu bar stops neither the control plane nor your agents.
- If this Mac's host can't join the control plane at first, for example because the
  control plane isn't listening yet or the network is down, **This Mac** says **Couldn't
  join the control plane:** and why, then **Trying again…**. It keeps its machine code and
  tries again by itself, at once when the Mac wakes or the network changes. Click **Try
  Again** to try now. The window shows the same line in **Settings ▸ Control plane**.
- If you already run a control plane elsewhere, choose **Join one elsewhere** in Agents
  Host instead, and paste a machine code from it. See
  [Add a machine](add-a-machine.md#add-another-mac).
- If you used the earlier Agents app on this Mac, Agents Host offers to move your agents,
  devices and servers across. See [Move an existing set-up across](move-an-existing-set-up.md).
- A control plane on this Mac has no address on the internet. Your iPhone and iPad reach
  it only on this Mac's network. To reach your agents away from home, and to be notified
  on your devices, run the control plane in the cloud. See
  [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md) and
  [Phone and iPad](../explanation/phone-and-ipad.md).

## Related

- [Connect a window or phone](connect-a-window-or-phone.md).
- [The window and the host](../explanation/window-and-daemon.md).
