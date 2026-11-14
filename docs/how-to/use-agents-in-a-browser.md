---
diataxis: how-to
devices: [mac, web]
description: Open Agent Loops in Safari or Chrome on the Mac that runs Agent Loops, pair the browser once, and forget it when you are done.
---

# Use Agent Loops in a browser

Agent Loops on a Mac serves Agent Loops as a web page, for a browser on the same Mac. The page is another
screen onto your agents, like the window and the phone. You can read and answer agents,
start and steer them, open their files and run workflows from a browser tab, without the
window open. Safari and Chrome are tested.

Only a browser on this Mac can reach the page. Using it from another computer waits on
serving it at a public address (issue #61).

## Before you start

- Agent Loops on this Mac, with the control plane here or connected to one elsewhere. See
  [Set up Agent Loops on this Mac](set-up-on-this-mac.md).
- The Agent Loops window, to get a code from.

## Steps

### Open the page and pair the browser

1. Turn on **Serve Agent Loops to browsers on this Mac** in **Settings ▸ Control plane**. It is
   off by default.
2. In the window, choose **View ▸ Open in Browser**. The same button is first on
   **Settings ▸ Control plane**, beside **Use Agent Loops in Safari or Chrome on this Mac**, and
   in the Agent Loops menu bar item.

   The page, **http://localhost:8792**, opens in your default browser. The first time, it
   pairs that browser in the same step: there is nothing to copy or paste.

   The page lists the folders on every host. With none yet, it says **No folders yet**, with
   **Add Folder…** and **Clone Folder from Git URL…** beside it. Its footer names the browser, as
   **Chrome on this Mac**. The window lists it under **Clients** as
   **Chrome on** followed by this Mac's name.

   If the page isn't being served, nothing opens, and it says why, as **Not serving: port
   8792 is in use by another app.**

### Pair a browser by hand

For a browser that isn't the default one, open **http://localhost:8792** in it. The page
says **Connect this browser to your agents**.

1. In the window, open **Settings ▸ Control plane**, click **Show** beside **Clients**, then
   click **Add a Browser…**.

   Click **Copy**. Whoever pastes the code can then do everything the window can, so paste
   it only into this page.
2. Paste the code into the page and click **Connect**.

The browser keeps a key of its own, which can't be copied out of it. Next time you open the
address, it connects with that key, and nothing needs pasting.

### With the control plane elsewhere

When this Mac reports to a control plane that runs somewhere else, such as in the cloud, this
Mac's host serves the page at the same address, **http://localhost:8792**. **Serve Agent Loops to
browsers on this Mac**, in **Settings ▸ Control plane**, turns it on and off, as before. It is
off by default.

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
[Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md#use-agent-loops-in-a-browser).

### What you can do there

A paired browser may do everything the window may (#111). The page shows what the iPhone
and iPad show, on every host:

- read a conversation as it happens, and answer permission requests and questions. With
  **Show Thoughts** (in the chat's **···** menu), each of the agent's thoughts is one folded line; off, they are not
  shown (see [Read a chat](read-a-chat.md));
- send a prompt with files or pictures attached, use **Send now** on a queued prompt, and
  change the mode, model or runtime;
- add a folder with **+** at the head of the folders column: **Add Folder…** chooses a
  folder on the host by typing a path or clicking into folders, and **Clone Folder from Git
  URL…** clones an HTTPS or SSH address into the host's home folder. With more than one
  host, the menu names each one;
- start an agent in the folder or in a new or existing worktree;
- stop, archive and unarchive a session, archive one that asks to be archived, mark it read
  or unread, and add or remove its labels;
- open a workflow's page, see its runs and run it now;
- open the agent's files and its changes, and follow a live page as the agent writes it, and
  type on it;
- answer a change that waits for an OK on its **Review** page;
- see a simulator on the session's Mac in the **Simulator** pane, and touch its screen;
- use a folder's connector views, such as the GitHub **Pull requests** and **Issues**, the
  GitLab merge requests and pipelines, and **Linear issues** (see [Use GitHub](use-github.md),
  [Use GitLab](use-gitlab.md) and [Use Linear issues](use-linear-issues.md));
- see **Cost**, **Tokens**, **Time**, **Events**, **Resources**, **Runtimes**, **Your
  Connectors** and **Worktrees** from the sidebar's Activity rows;
- open **Settings**: **Sidebar** (which smart
  groups show), **Finished chats**, **Machine providers**, **Git access**, **Versions**,
  **Backups** and **People**.

The tab's title counts the sessions that need you, as **(2) Agent Loops**.

A folder can't be dragged in from Finder to add a folder. Signing runtimes in, pairing a
window or a phone, and adding a server by ssh have no screens on the page yet, so do them in
the window. **Clone Folder from Git URL…** doesn't fill in a
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

### Pair by your account

When a sign-in provider is on, the page on the control plane's own address shows **Sign in
with your account** above the code. Type the email of your Google or Apple sign-in, or your
GitHub login. The page shows a code. On one of your signed-in Macs, iPhones or iPads, type that
code on the card that says the browser wants to sign in as you, and select **Approve**. The
browser pairs as you. See [Sign in with Google, Apple or
GitHub](sign-in-with-google-apple-or-github.md#pair-a-browser-by-your-approval).

### Sign in with your organisation's provider

When the organisation added its own sign-in provider, the page on the control plane's own
address shows **Sign in with Acme Okta** above the code, and **Use an Email** when its email
domain is claimed. Select it, sign in at the provider, and the browser comes back to the page
paired, with no code. The page keeps no token: it keeps only its own key, as with a code. The
page on this Mac (`localhost`) does not show the button. See [Sign in with Google, Apple or
GitHub](sign-in-with-google-apple-or-github.md#sign-in-with-your-organisations-provider).

## If it doesn't work

- **This code has expired. Ask for a new one.** A code works for five minutes. Get a new one.
- **This code has been used. Ask for a new one.** A code works once.
  An address with `#code=` in it, from the browser's history, is one of these: choose **Open in
  Browser** again instead.
- **That isn't an Agent Loops code. It starts agents-control:2:c:** Something else was pasted, or a
  code for a host. Copy the code again from **Add a Browser…**.
- **This code is for another control plane.** The code came from a different set-up from the
  one serving this page.
- **That code is for a window or a phone. Get one from Add a Browser….** A code from **Pair a
  Device…** or **Pair a Mac…** works only for those. Get one made for a browser. It works the
  other way too: a browser's code pasted into a phone or a window says **That code is for a
  browser. Paste it in the Agent Loops page.**
- **Can't reach the control plane at localhost:8792. Trying again.** The control plane on
  this Mac has stopped. The page shows what it last knew, and catches up by itself when the
  control plane is back, with no reload.
- **Your organisation's sign-in turned your access off.** Your organisation's provider
  suspended you. The browser stays paired, and opens again by itself when they turn your
  access on.
- **This sign-in took too long, or started in another browser.** Select **Sign in with …**
  again in this browser.
- **This browser isn't supported.** The browser can't keep a key that can't be copied out of
  it. Use the current Safari or Chrome.
- **The page doesn't load at all.** Check that **Serve Agent Loops to browsers on this Mac** is on
  in **Settings ▸ Control plane**, and that the address is `localhost`, not this Mac's network name. A page
  that says only **Connecting…** has a key and is waiting for the control plane to answer.
- **Chrome's console reports a Content Security Policy violation for
  `/.well-known/appspecific/com.chrome.devtools.json`.** Chrome DevTools asks for that file by
  itself while it is open, and the page's policy lets it talk only to its own WebSocket. The
  page answers it with a 404. It is harmless and doesn't stop the page.
- **Not serving: port 8792 is in use by another app.** **Settings ▸ Control plane** says
  this under **Serve Agent Loops to browsers on this Mac**, when something else had the port
  first. Whatever answers at that address isn't Agent Loops: don't paste a code into it. Quit what holds the port
  (`lsof -nP -iTCP:8792`) and press **Try Again**.
- **That isn't allowed from this browser. The Mac's Agent Loops may need updating.** An older
  Agent Loops (then named Agents Host) still judges the browser by a grant. Update it.
- **That host can't do that yet. It may need updating.** The host is older than the page.

## Related

- [Connect a window or phone](connect-a-window-or-phone.md).
- [How the phone and iPad reach your agents](../explanation/phone-and-ipad.md).
- [The control plane](../explanation/control-plane.md).
