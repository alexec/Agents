---
diataxis: how-to
devices: [mac]
description: Add a folder or clone a Git URL as a folder, and archive a folder you are done with.
---

# Add a folder

A folder is a directory you work in. Every agent belongs to one. You add folders on the
Mac; your iPhone and iPad show the same list.

To ask an agent something that needs no repository, add any folder, such as an empty one,
as a folder.

## Before you start

- At least one runtime installed on this Mac. If the list says **No agent runtime found**,
  install one first; see [Runtimes](../reference/runtimes.md) for what each needs.
- To clone, the Git address of the repository, and access to it from this Mac (the same
  access `git clone` would need in Terminal).

## Steps

**Add a folder that is already on your Mac**

1. Choose **File ▸ Add Folder…** (⌘O). With no folders yet, you can click
   **Add Folder…** in the list instead.
2. Pick the folder and click **Open**.

   The folder appears in the list, named after the folder, and its page opens beside it.

**Clone a repository**

1. Copy the repository's HTTPS or SSH address, such as
   `https://github.com/example/repo.git`.
2. Choose **File ▸ Clone Folder from Git URL…** (⇧⌘O). With no folders yet, click
   **Clone Folder from Git URL…** instead.

   The sheet **Clone a Git repository** opens with the address you copied already in it.
   Under the address it says where the clone will go, for example
   **Clones into ~/repo and adds it as a folder.**
3. Click **Clone**.

   The sheet closes at once. The folder appears in the list with **Cloning…** under its
   name while it downloads, then becomes an ordinary folder.

   If you have added a server, the **+** menu has **This Mac** and one entry per
   server; pick where the folder should live first. See
   [Add a machine](add-a-machine.md).

**Put a folder in a project**

Each folder you add is in a project of its own name. Nothing is asked. The project's id
goes into the folder's `.agents/folder.json`. Commit that file, and a clone of the
repository on another machine joins the same project.

1. On the Mac, select the folder and choose **File ▸ Folder Settings…**. On the iPhone,
   iPad or web page, open the folder's menu and choose **Project…**.
2. Under **Project**, pick another project, or choose **New Project…** and type a name.

   To rename the project, choose **Rename Project…**. Only the person who made it, or an
   admin, can rename it.

**Archive a folder you are done with**

1. Stop any agent in the folder that is still working. See
   [Stop and archive agents](archive-and-stop.md).
2. Right-click the folder in the list and choose **Archive**.

   The folder moves under **Archived** at the bottom of the list, with when you archived
   it. Its folder, its agents and their conversations are kept, and its workflows stop
   running until it comes back.
3. To unarchive it, open **Archived** and click **Unarchive** beside the folder.

There is no separate way to remove a folder: archive it, and delete the folder in Finder
if you no longer want it. **Show in Finder** on the same menu takes you there.

## If it doesn't work

- **Stop these first:** followed by agent names means those agents are still working.
  Stop them, then archive again.
- **That is not a Git URL this app can clone.** The address is not one Git understands.
  Paste the HTTPS or SSH address from the repository's **Clone** button.
- **.agents/folder.json names a project id that is not valid** under **Project**: the file
  was changed by hand. Pick a project, and a good id is written.
- **Folder is missing** under a folder's name means the folder was moved or deleted
  outside the app. Put it back, or archive the folder.

## See also

- [Add a machine](add-a-machine.md)
- [Start an agent in its own worktree](start-in-a-worktree.md)
- [Folders, hosts and worktrees](../explanation/folders-machines-worktrees.md)
- [Runtimes](../reference/runtimes.md)
