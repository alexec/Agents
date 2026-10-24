---
diataxis: how-to
devices: [mac, iphone, ipad, browser]
description: Keep a document or an HTML page under its folder in the sidebar, open live in one click.
---

# Pin a page to a folder

You can pin the documents and pages you come back to under their folder, such as a
roadmap, a coverage report or a review. They sit under the folder in the sidebar and open
where a chat would be, live as the file changes, as a page an agent shows you does.

## Pin one

On the Mac or the web page, open the file in the files pane beside a conversation and
click the pin in the pane's bar. Click it again to unpin. Pinning is yours: agents have no
tool to pin, unpin or move a pin. Pins an agent made before those tools went stay, with
its name, until you unpin them.

Only Markdown (`.md`) and HTML (`.html`) files in the folder can be pinned. A folder holds
at most 10 pins; at 10, **Pin to Folder** is greyed until one is unpinned.

## Read one

- **On the Mac and the web page**, unfold the folder in the sidebar. Its pins are first,
  under its row and above its sessions. Click one.
- **On the iPhone or iPad**, open the folder. Its pins are above its sessions.

A Markdown page follows the file and takes your typing, as a live document does (see
[Follow a live document](follow-a-live-document.md)). An HTML page is drawn with its
stylesheets and pictures, with scripts and the network off (see
[Look at an HTML page](look-at-an-html-page.md)); on the web page it shows as its source.

## Order and unpin them

- **Drag** a pin among the pins in the sidebar, on the Mac and the web page. On the
  iPhone and iPad, long-press a pin for **Move Up** and **Move Down**.
- **Unpin** is in a pin's context menu (long press on the phone) and at the top of its
  page. You can unpin any pin.

## When a pinned file moves or goes

The pin stays, its row says **Missing**, and its page says the file isn't in the folder
folder, with **Unpin**. If the file comes back (a pull, a branch landing, an undo), the pin
works again by itself. Pins don't follow a rename: pin the new path and unpin the old.

A pin opens the **folder's** copy of the file, never a worktree's.

## Where pins are kept

In the folder, in `.agents/pins.json`, in the order shown. The
app writes it, only from your clicks, only in the folder, never in
a worktree, and never commits it: it shows in the folder's changes and goes in with
whatever is committed next, so pins travel with the folder.

## See also

- [Tools the app gives agents](../reference/agent-tools.md)
