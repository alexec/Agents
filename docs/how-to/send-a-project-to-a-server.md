---
diataxis: how-to
devices: [mac, server]
description: Send a repository on this Mac to a server, with its unpushed branches and uncommitted changes, and add it there as a project.
---

# Send a project to a server

To continue work on a server, the code must be there, including a branch that you did not
push and changes that you did not commit. A clone on the server gets only what is pushed.
**Send to ‹server›…** sends this Mac's repository to the server and adds it there as a
project.

## Before you start

- A server that is a host of your control plane, and online. See [Add a server](add-a-server.md).
- Git on the server.
- A project, or a worktree, on this Mac that is a Git repository with at least one commit.

## Steps

1. In the sidebar, right-click the project and choose **Send to ‹server›…**. For a
   worktree, open **Activity ▸ Worktrees**, right-click the worktree and choose
   **Send to ‹server›…**.
2. Check **Folder on ‹server›**. It is `~/‹name of the project›` at first. Press Return
   after you change it, and the sheet says what is there:
   - **A new copy**: the folder is not there, or it is empty.
   - **‹server› has a copy here**: a send made it before. Only the commits that it does
     not have go.
3. Choose the branches to send. The branch that is checked out on this Mac is chosen at
   first.
4. Keep **Include uncommitted changes** on to send the changed files and the new files that
   git does not ignore. Files that git ignores, such as `node_modules` and `build`, do not
   go. The changes go only with the branch that is checked out on this Mac.
5. Click **Send**.

   The sheet shows the progress. When the server has the copy, the project is listed under the
   server's heading. The copy on the server has the same `origin` as this Mac's, so a push
   from the server goes to the same repository.

## Send again

Do the same steps again to bring the copy on the server up to date. Only the commits that
the server does not have go. The uncommitted changes of the last send are replaced by the
uncommitted changes of this send.

A send never overwrites work done on the server. The send stops, and changes nothing, when:

- the copy on the server has changes of its own. Commit them or remove them on the server,
  then send again;
- a branch on the server has commits of its own that this Mac does not have.

## How it works

This Mac's host makes a `git bundle` of the branches, without the commits that the server
has, and a patch of the uncommitted changes. The patch is made with an index of its own, so
the index of your repository does not change. The window sends both to the server in parts
of 8 MB, over the connection it already has to the server through the control plane. The
server fetches from the bundle, moves each branch forward (never back), checks out the
branch, applies the patch and adds the folder as a project.
