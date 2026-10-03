---
diataxis: how-to
devices: [mac, iphone, ipad, browser]
description: Keep a document or an HTML page under its project in the sidebar, beside the Dashboard, open live in one click.
---

# Pin a page to a project

A project's **Dashboard** is the page its own row opens. Beside it you can pin the
documents and pages you come back to, such as a roadmap, a coverage report or a review.
They sit under the project in the sidebar and open where a chat would be, live as the
file changes, as a page an agent shows you does.

## Pin one

- **Ask an agent.** For example: "Pin docs/roadmap.md to the project as Roadmap." Agents
  pin with the `pin_page` tool, and are told to pin what lasts rather than what they are
  writing this turn.
- **On the Mac or the web page**, open the file in the files pane beside a conversation and
  click the pin in the pane's bar. Click it again to unpin.
- **From a page tile** on the Dashboard, click **Open**, then **Pin to Project**.

Only Markdown (`.md`) and HTML (`.html`) files in the project can be pinned. A project holds
at most 10 pins; at 10, **Pin to Project** is greyed and an agent's `pin_page` is refused,
saying so, until one is unpinned.

## Read one

- **On the Mac and the web page**, unfold the project in the sidebar. Its pins are first,
  under its row and above its sessions. Click one.
- **On the iPhone or iPad**, open the project. Its pins are under the **Dashboard** row.

A Markdown page follows the file and takes your typing, as a live document does (see
[Follow a live document](follow-a-live-document.md)). An HTML page is drawn with its
stylesheets and pictures, with scripts and the network off (see
[Look at an HTML page](look-at-an-html-page.md)); on the web page it shows as its source.

## Order and unpin them

- **Drag** a pin among the pins in the sidebar, on the Mac and the web page. On the
  iPhone and iPad, long-press a pin for **Move Up** and **Move Down**.
- **Unpin** is in a pin's context menu (long press on the phone) and at the top of its
  page. You can unpin any pin. An agent can unpin only the pins it pinned.

## When a pinned file moves or goes

The pin stays, its row says **Missing**, and its page says the file isn't in the project
folder, with **Unpin**. If the file comes back (a pull, a branch landing, an undo), the pin
works again by itself. Pins don't follow a rename: pin the new path and unpin the old.

A pin opens the **project folder's** copy of the file. One an agent pins from its worktree
shows as missing until its branch lands in the project folder.

## Where pins are kept

In the project, in `.agents/pins.json`, beside `.agents/dashboard/`, in the order shown. The
app writes it, only through its tools and your clicks, only in the project folder, never in
a worktree, and never commits it: it shows in the project's changes and goes in with
whatever is committed next, so pins travel with the project.

## See also

- [Keep a project Dashboard](keep-a-project-dashboard.md), and its `page` tile, which draws
  a document on the Dashboard itself
- [Tools the app gives agents](../reference/agent-tools.md), for `pin_page`, `unpin_page`
  and `move_pin`
