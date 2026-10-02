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
- If you want the control plane's store in a bucket rather than on this Mac: the bucket's
  endpoint, name, region and an access key and secret for it. You can also switch later.

## Steps

### Run the control plane here

1. Open Agents. With no control plane set up, it asks **Where should your agents run?**
2. Under **Set one up on this Mac**, click **Get Agents Host…**. Download and install
   Agents Host, then open it. It lives in the menu bar; its window opens the
   first time.
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
   **THIS MAC** in the projects list. Add a project to start; see
   [Add a project](add-a-project.md).

The code works once, for five minutes. If it runs out, close the sheet and click **Pair**
again. You can also open the sheet from the Agents Host menu bar item, with **Pair a
Window or Phone…**.

### Keep the store in a bucket instead

The control plane keeps what it remembers (paired windows and devices, and your hosts) in a
folder on this Mac by default. In a bucket, it outlives this Mac, and copies elsewhere can
share it later.

1. In Agents Host, under **CONTROL PLANE**, set **Keeps its store** to **In a bucket**.
2. Fill in **Endpoint**, **Bucket**, **Prefix**, **Region**, **Access key** and
   **Secret**.
3. Click **Check**. It says **Works, with safe concurrent writes** when the bucket can be
   used.
4. Click **Switch Store…**, then **Switch Store**.

   The control plane stops for a moment while every record is copied across. Windows,
   phones and hosts reconnect by themselves, and nothing needs pairing again. The old
   store is kept. The bucket's keys are kept only in this Mac's keychain.

To go back, set **Keeps its store** to **On this Mac** and click **Switch Store…** again.

## What to know

- While this Mac sleeps, or is off your network, no window or device can reach any of
  your agents, including agents on servers. They keep working, and you see them again when
  the Mac is back. To avoid that, run the control plane elsewhere; see
  [Run the control plane as several copies](run-several-copies.md).
- Quitting Agents Host from the menu bar stops neither the control plane nor your agents.
- If you already run a control plane elsewhere, choose **Join one elsewhere** in Agents
  Host instead, and paste a host code from it. See
  [Add a server](add-a-server.md#add-another-mac).
- If you used the earlier Agents app on this Mac, Agents Host offers to move your agents,
  devices and servers across. See [Move an existing set-up across](move-an-existing-set-up.md).
- The **Relay for my devices** row, which lets your iPhone and iPad reach you through
  iCloud when away, says **Not in this build yet**.

## Related

- [Connect a window or phone](connect-a-window-or-phone.md).
- [The window and the host](../explanation/window-and-daemon.md).
