---
diataxis: how-to
devices: [mac, web]
description: Open Agents in Safari or Chrome on the Mac that runs Agents Host, pair the browser once, and forget it when you are done.
---

# Use Agents in a browser

Agents Host serves Agents as a web page, for a browser on the same Mac. The page is another
screen onto your agents, like the window and the phone. You can read and answer agents,
start and steer them, open their files and run workflows from a browser tab, without the
window open. Safari and Chrome are tested.

Only a browser on this Mac can reach the page. Using it from another computer waits on
serving it at a public address (issue #61).

## Before you start

- Agents Host on this Mac, running the control plane here or joined to one elsewhere. See
  [Set up Agents on this Mac](set-up-on-this-mac.md).
- A paired window, or Agents Host itself, to get a code from.

## Steps

### Open the page and pair the browser

1. In the window, choose **View ▸ Open in Browser**. The same button is first on
   **Settings ▸ Control plane**, beside **Use Agents in Safari or Chrome on this Mac**, and in
   Agents Host beside **Serve Agents to browsers on this Mac** and in its menu.

   The page, **http://localhost:8792**, opens in your default browser. The first time, it
   pairs that browser in the same step: there is nothing to copy or paste.

   The page lists the projects on every host. With none yet, it says **No projects yet**, with
   **Add Project…** and **Clone Project from Git URL…** beside it. Its footer names the browser, as
   **Chrome on this Mac**. The window lists it under **Clients** as
   **Chrome on** followed by this Mac's name.

   If the page isn't being served, nothing opens, and it says why, as **Not serving: port
   8792 is in use by another app.**

### Pair a browser by hand

For a browser that isn't the default one, open **http://localhost:8792** in it. The page
says **Connect this browser to your agents**.

1. Get a code, from either place:
   - In the window, open **Settings ▸ Control plane**, click **Show** beside **Clients**, then
     click **Add a Browser…**.
   - In Agents Host, click **Pair a Window or Phone…** and choose **A browser on this Mac**.

   Click **Copy**. Whoever pastes the code can then do everything the window can, so paste
   it only into this page.
2. Paste the code into the page and click **Connect**.

The browser keeps a key of its own, which can't be copied out of it. Next time you open the
address, it connects with that key, and nothing needs pasting.

### With the control plane elsewhere

When this Mac joins a control plane that runs somewhere else, such as in the cloud, this Mac's
host serves the page at the same address, **http://localhost:8792**. **Serve Agents to browsers
on this Mac** in Agents Host turns it on and off, as before.

The page works as it does with the control plane here, with two differences:

- **Open in Browser** is not offered. Pair the browser by hand, as above: get the code from
  **Add a Browser…** in the window, or at the foot of the Remote's sidebar.
- The page needs the control plane. This Mac's host passes the page through to it, and the
  control plane checks the browser. When the control plane can't be reached, the page says it
  is offline, and connects again once it can.

A browser paired at this address while the control plane ran on this Mac keeps working after
the control plane moves, because its key and the address stay the same.

### A browser on another computer

A control plane in the cloud serves the same page at its own address, such as
`https://agents.example.com/`, for a browser anywhere. **Add a Browser…** in the window, or
at the foot of the Remote's sidebar, gives the code and says the address. See
[Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md#use-agents-in-a-browser).

### What you can do there

A paired browser may do everything the window may (#111). The page shows what the iPhone
and iPad show, on every host:

- read a conversation as it happens, and answer permission requests and questions. With
  **Show thoughts** on, each of the agent's thoughts is one folded line; off, they are not
  shown (see [Read a chat](read-a-chat.md));
- send a prompt with files or pictures attached, use **Send now** on a queued prompt, and
  change the mode, model or runtime;
- start a chat with **New Chat** at the top of the **+** menu, in the host's **chat**
  project (see [Chat without a project](chat-without-a-project.md));
- add a project with **+** at the head of the projects column: **Add Project…** chooses a
  folder on the host by typing a path or clicking into folders, and **Clone Project from Git
  URL…** clones an HTTPS or SSH address into the host's home folder. With more than one
  host, the menu names each one;
- start an agent in the project folder or in a new or existing worktree;
- stop, archive and unarchive a session, archive one that asks to be archived, mark it read
  or unread, and add or remove its labels;
- open a workflow's page, see its runs and run it now;
- open the agent's files and its changes, and follow a live page as the agent writes it, and
  type on it;
- answer a change that waits for an OK on its **Review** page;
- see a simulator on the session's Mac in the **Simulator** pane, and touch its screen;
- use a project's connector views, such as the GitHub **Pull requests** and **Issues**, the
  GitLab merge requests and pipelines, and **Linear issues** (see [Use GitHub](use-github.md),
  [Use GitLab](use-gitlab.md) and [Use Linear issues](use-linear-issues.md));
- see **Cost**, **Tokens**, **Time**, **Events**, **Resources**, **Runtimes**, **Your
  Connectors** and **Worktrees** from the sidebar's Activity rows;
- open **Settings**: **Appearance** (with **Show thoughts**), **Sidebar** (which smart
  groups show), **Finished chats**, **Workspace providers**, **Git access**, **Versions**,
  **Backups** and **People**.

The tab's title counts the sessions that need you, as **(2) Agents**.

A folder can't be dragged in from Finder to add a project. Signing runtimes in, pairing a
window or a phone, and adding a server by ssh have no screens on the page yet, so do them in
the window. **Clone Project from Git URL…** doesn't fill in a
copied address, because the page doesn't read the clipboard. The page has no terminal and no
dictation.

### Install it as an app

The page installs as an app of its own, with the Blob icon and its own window:

- **Chrome:** click the install button at the end of the address bar, or choose **Cast, Save, and
  Share ▸ Install Page as App…** in the **⋮** menu.
- **Safari:** choose **File ▸ Add to Dock…**.

Safari's app keeps its own website data, so it isn't paired by the tab's key: pair it once by hand,
as in [Pair a browser by hand](#pair-a-browser-by-hand). Chrome's app shares the browser's key.
The page is served only to this Mac for now, so it can't be added to a phone's home screen
until it is served at a public address (#61).

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
  An address with `#code=` in it, from the browser's history, is one of these: choose **Open in
  Browser** again instead.
- **That isn't an Agents code. It starts agents-control:2:c:** Something else was pasted, or a
  code for a host. Copy the code again from **Add a Browser…**.
- **This code is for another control plane.** The code came from a different set-up from the
  one serving this page.
- **That code is for a window or a phone. Get one from Add a Browser….** A code from **Pair a
  Device…** or **Pair a Mac…** works only for those. Get one made for a browser. It works the
  other way too: a browser's code pasted into a phone or a window says **That code is for a
  browser. Paste it in the Agents page.**
- **Can't reach the control plane at localhost:8792. Trying again.** Agents Host's control
  plane has stopped. The page shows what it last knew, and catches up by itself when the
  control plane is back, with no reload.
- **This browser isn't supported.** The browser can't keep a key that can't be copied out of
  it. Use the current Safari or Chrome.
- **The page doesn't load at all.** Check that **Serve Agents to browsers on this Mac** is on
  in Agents Host, and that the address is `localhost`, not this Mac's network name. A page
  that says only **Connecting…** has a key and is waiting for the control plane to answer.
- **Chrome's console reports a Content Security Policy violation for
  `/.well-known/appspecific/com.chrome.devtools.json`.** Chrome DevTools asks for that file by
  itself while it is open, and the page's policy lets it talk only to its own WebSocket. The
  page answers it with a 404. It is harmless and doesn't stop the page.
- **Not serving: port 8792 is in use by another app.** Agents Host says this under the switch,
  and **Settings ▸ Control plane** says it too, when something else had the port first. Whatever
  answers at that address isn't Agents: don't paste a code into it. Quit what holds the port
  (`lsof -nP -iTCP:8792`) and press **Try Again**.
- **That isn't allowed from this browser. The Mac's Agents may need updating.** An older
  Agents Host still judges the browser by a grant. Update it.
- **That host can't do that yet. It may need updating.** The host is older than the page.

## Related

- [Connect a window or phone](connect-a-window-or-phone.md).
- [How the phone and iPad reach your agents](../explanation/phone-and-ipad.md).
- [The control plane](../explanation/control-plane.md).
