---
diataxis: how-to
devices: [mac]
description: Open Agents in Safari or Chrome on the Mac that runs Agents Host, pair the browser once, and forget it when you are done.
---

# Use Agents in a browser

Agents Host serves Agents as a web page, for a browser on the same Mac. The page is another
screen onto your agents, like the window and the phone. You can read and answer agents,
start and steer them, open their files and run workflows from a browser tab, without the
window open, in the current Safari or Chrome.

Only a browser on this Mac can reach the page. Using it from another computer waits on
serving it at a public address (issue #61).

## Before you start

- Agents Host on this Mac, running the control plane here. See
  [Set up Agents on this Mac](set-up-on-this-mac.md).
- A paired window, or Agents Host itself, to get a code from.

## Steps

### Open the page

1. Open Agents Host. Under **This Mac**, check that **Serve Agents to browsers on this Mac**
   is on. The line under it gives the page's address, **http://localhost:8792**.
2. Open that address in Safari or Chrome on this Mac.

   The page says **Connect this browser to your agents**.

### Pair the browser

1. Get a code, from either place:
   - In the window, open **Settings ▸ Control plane**, click **Show** beside **Clients**, then
     click **Pair a Browser…**.
   - In Agents Host, click **Pair a Window or Phone…** and choose **A browser on this Mac**.

   Under **It may**, leave **what a phone can (Device)** chosen unless the browser needs to
   do everything. Click **Copy**.
2. Paste the code into the page and click **Connect**.

   The page lists the projects on every host. Its footer names the browser and its grant, as
   **Chrome on this Mac · Device**. The window lists it under **Clients** as
   **Chrome on** followed by this Mac's name.

The browser keeps a key of its own, which can't be copied out of it. Next time you open the
address, it connects with that key, and nothing needs pasting.

### What you can do there

With the device grant, the page does what the iPhone and iPad do, on every host:

- read a conversation as it happens, at **Outcome**, **Steps** or **Details**, and answer
  permission requests and questions;
- send a prompt with files or pictures attached, use **Send now** on a queued prompt, and
  change the mode, model or runtime;
- start an agent in the project folder or in a new or existing worktree;
- stop, park, unpark, archive and bring back a session, mark it read or unread, and add or
  remove its labels;
- see a project's workflows and run one now;
- open the agent's files and its changes, and follow a live page as the agent writes it, and
  type on it.

The tab's title counts the sessions that need you, as **(2) Agents**.

Settings, adding projects, signing runtimes in, pairing and hosts stay in the window. The
page has no terminal and no dictation.

### Forget the browser

- From the page itself: click **Forget This Browser…** in the footer, then **Forget**.
- From the window: open **Settings ▸ Control plane ▸ Clients**, click **Forget…** beside the
  browser, then **Forget**.

Either way it is cut off at once, in every tab. The page says **This browser was forgotten.
Pair it again to carry on.**

Clearing the site's data for `localhost`, or closing a private window, also loses the key.
The control plane still lists the browser until you forget it there.

## If it doesn't work

- **This code has expired. Ask for a new one.** A code works for five minutes. Get a new one.
- **This code has been used. Ask for a new one.** A code works once.
- **That isn't an Agents code. It starts agents-control:2:c:** Something else was pasted, or a
  code for a host. Copy the code again from **Pair a Browser…**.
- **This code is for another control plane.** The code came from a different set-up from the
  one serving this page.
- **That code is for a window or a phone. Get one from Pair a Browser….** A code from **Pair a
  Device…** or **Pair a Mac…** works only for those. Get one made for a browser. It works the
  other way too: a browser's code pasted into a phone or a window says **That code is for a
  browser on this Mac.**
- **Can't reach the control plane at localhost:8792. Trying again.** Agents Host's control
  plane has stopped. The page shows what it last knew, and catches up by itself when the
  control plane is back, with no reload.
- **This browser isn't supported.** The browser can't keep a key that can't be copied out of
  it. Use the current Safari or Chrome.
- **The page doesn't load at all.** Check that **Serve Agents to browsers on this Mac** is on
  in Agents Host, and that the address is `localhost`, not this Mac's network name.
- **This browser's grant doesn't allow that.** The browser was paired as a device. Change it
  to **Operator** in **Settings ▸ Control plane ▸ Clients** if it needs to.

## Related

- [Connect a window or phone](connect-a-window-or-phone.md).
- [How the phone and iPad reach your agents](../explanation/phone-and-ipad.md).
- [The control plane](../explanation/control-plane.md).
