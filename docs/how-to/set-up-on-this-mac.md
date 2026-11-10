---
diataxis: how-to
devices: [mac]
description: Install Agents on this Mac. It runs your agents and the control plane here, and the window pairs itself.
---

# Set up Agents on this Mac

Your agents run on a host, and every window and phone reaches them through a control plane
you own (see [The control plane](../explanation/control-plane.md)). On a Mac, one app,
**Agents**, has all three: the window, this Mac's host (`agentsd`) and a control plane.
The first time you open it, it sets them up with no question.

## Before you start

- A Mac on which you can install apps in your home folder.
- Agents is a free download from us. It is not in the Mac App Store, because it runs
  programs for your agents. The iPhone and iPad app is in the App Store and on TestFlight.

## Steps

### Install Agents

1. Download Agents from the latest release on GitHub,
   [github.com/alexec/Agents/releases/latest](https://github.com/alexec/Agents/releases/latest).

   The release has `Agents-<version>.dmg` and `Agents-<version>.zip`, with the same app in
   them. Neither needs admin rights. If your Mac does not open a disk image (because of a
   company policy, for example), download the `.zip` instead and double-click it.
2. Drag Agents into `~/Applications`, the Applications folder in your home folder. You can
   always write to it. `/Applications` asks for an admin's password.

   In `~/Applications`, Agents updates itself to the release your control plane runs, with
   no admin password (#2178). It restarts only when no agent is in a turn.
   **Settings ▸ Machines ▸ This Mac ▸ Updates** shows the update, and
   **Update Agents automatically** turns it off.

### Open it

1. Open Agents.

   The window says **Setting up Agents on this Mac…**, then **Connecting this window…**.
   In these steps, Agents:

   - makes the control plane's key;
   - registers two login items with macOS, the control plane and this Mac's host, and
     starts them;
   - joins this Mac's host to the control plane;
   - pairs the window with the control plane.

   You copy and paste no code.
2. When it is done, the window shows the session list, with a **Get started** card at the
   top of the sidebar. Add a folder to start; see [Add a folder](add-a-folder.md).

If macOS asks you to allow Agents in **Login Items**, the window says so and shows
**Open Login Items**. Click it, turn on **Agents** under **Allow in the Background**, and
come back. Agents sees the change and continues by itself.

If a step fails, the window shows one line that says what went wrong, with **Try Again**
and **Show Details**. See
[Fix Agents when it won't start](fix-agents-host-not-starting.md).

### The menu bar item

Agents also has an item in the menu bar. It shows how many agents work and how many need
you, also when no window is open. It has **Open Agents**, **Pair a Phone or iPad…**,
**Open in Browser**, **Settings…** and **Quit Agents**.

## What to know

- **Quit Agents** closes the window and the menu bar item. It does not stop the control
  plane or your agents. At login, macOS starts them and the menu bar item, but not the
  window.
- The control plane keeps what it remembers (paired windows and devices, and your
  machines) in a folder on this Mac. To keep it in the cloud, run the control plane there.
  See [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md).
- While this Mac sleeps, or is off your network, no window or device can reach any of your
  agents, including agents on servers. They keep working, and you see them again when the
  Mac is back. To prevent that, run the control plane elsewhere. See
  [Run the control plane as several copies](run-several-copies.md).
- If this Mac's host cannot join the control plane (for example, because the control plane
  does not listen yet or the network is down), **Settings ▸ Machines ▸ This Mac** says
  **Couldn't join the control plane:** and why, then **Trying again…**. The host keeps its
  machine code and tries again by itself, immediately when the Mac wakes or the network
  changes. Click **Try Again** to try now. **Settings ▸ Control plane** shows the same line
  under **This Mac as a machine**.
- If you already run a control plane elsewhere, or want Hosted at agentloops.dev, open
  **Settings ▸ Control plane** and click **Connect to Another…**. See
  [Connect a window or phone](connect-a-window-or-phone.md#connect-this-mac-to-another-control-plane).
- A control plane on this Mac has no address on the internet. Your iPhone and iPad reach
  it only on this Mac's network. To reach your agents away from home, and to get
  notifications on your devices, run the control plane in the cloud. See
  [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md) and
  [Phone and iPad](../explanation/phone-and-ipad.md).
- To remove Agents, open **Settings ▸ Machines ▸ This Mac** and click
  **Remove Agents from This Mac…** first. It stops both login items and removes them. Then
  quit Agents and move it to the Trash. If you only move it to the Trash, the login items
  stay, and macOS keeps them in **Login Items**.

## Related

- [Connect a window or phone](connect-a-window-or-phone.md).
- [The window and the host](../explanation/window-and-daemon.md).
