---
diataxis: how-to
devices: [mac]
description: Add a folder or clone a Git URL as a project, and archive a project you are done with.
---

# Add a project

A project is a folder you work in. Every agent belongs to one. You add projects on the
Mac; your iPhone and iPad show the same list.

## Before you start

- At least one runtime installed on this Mac. If the list says **No agent runtime found**,
  install one first; see [Reference](../reference/index.md) for what each runtime needs.
- To clone, the Git address of the repository, and access to it from this Mac (the same
  access `git clone` would need in Terminal).

## Steps

**Add a folder that is already on your Mac**

1. Click **+** (**New project**) at the top of the **Projects** list and choose
   **Choose Folder…**. With no projects yet, you can click **Add a folder** in the list
   instead.
2. Pick the folder and click **Open**.

   The project appears in the list, named after the folder, and its page opens beside it.

**Clone a repository**

1. Copy the repository's HTTPS or SSH address, such as
   `https://github.com/example/repo.git`.
2. Click **+** (**New project**) and choose **Clone Git URL…**. With no projects yet, click
   **Clone a Git URL** instead.

   The sheet **Clone a Git repository** opens with the address you copied already in it.
   Under the address it says where the clone will go, for example
   **Clones into ~/repo and adds it as a project.**
3. Click **Clone**.

   The sheet closes at once. The project appears in the list with **Cloning…** under its
   name while it downloads, then becomes an ordinary project.

   If you have added a Linux server, the **+** menu has **This Mac** and one entry per
   server; pick where the project should live first. See
   [Add a Linux server](add-a-linux-server.md).

**Archive a project you are done with**

1. Stop any agent in the project that is still working. See
   [Stop, park and archive agents](archive-park-stop.md).
2. Right-click the project in the list and choose **Archive**.

   The project moves under **Archived** at the bottom of the list, with when you archived
   it. Its folder, its agents and their conversations are kept, and its workflows stop
   running until it comes back.
3. To bring it back, open **Archived** and click **Unarchive** beside the project.

There is no separate way to remove a project: archive it, and delete the folder in Finder
if you no longer want it. **Show in Finder** on the same menu takes you there.

## If it doesn't work

- **Stop these first:** followed by agent names means those agents are still working.
  Stop them, then archive again.
- **That is not a Git URL this app can clone.** The address is not one Git understands.
  Paste the HTTPS or SSH address from the repository's **Clone** button.
- **Folder is missing** under a project's name means the folder was moved or deleted
  outside the app. Put it back, or archive the project.
