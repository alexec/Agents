---
diataxis: how-to
devices: [mac, server]
description: Send a repository on this Mac to a server, with its unpushed branches and uncommitted changes, add it there as a folder, and bring the server's work back.
---

# Send a folder to a server

To continue work on a server, the code must be there, including a branch that you did not
push and changes that you did not commit. A clone on the server gets only what is pushed.
**Send to ‹server›…** sends this Mac's repository to the server and adds it there as a
folder.

## Before you start

- A server that is a host of your control plane, and online. See [Add a machine](add-a-machine.md).
- Git on the server.
- A folder, or a worktree, on this Mac that is a Git repository with at least one commit.

## Steps

1. In the sidebar, right-click the folder and choose **Send to ‹server›…**. For a
   worktree, open **Activity ▸ Worktrees**, right-click the worktree and choose
   **Send to ‹server›…**.
2. Check **Folder on ‹server›**. It is `~/‹name of the folder›` at first. Press Return
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

   The sheet shows the progress. When the server has the copy, the folder is listed under the
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

## Bring the work back

Work done on the server does not come to this Mac until you push it, or bring it back.
**Bring Back from ‹server›…** brings the server's branches into the repository on this Mac.

1. Right-click the folder, or the worktree on **Activity ▸ Worktrees**, and choose
   **Bring Back from ‹server›…**.
2. Check **Folder on ‹server›**. It is `~/‹name of the folder›` at first: the folder that
   the send made. Press Return after you change it.
3. Choose the branches to bring back. The branch that is checked out on the server is chosen
   at first. A branch that this Mac does not have is made.
4. To bring back the changes that are not committed on the server too, turn on
   **Include uncommitted changes from ‹server›**. It is off at first. The changes come back
   only to a folder that has the same branch checked out, and that folder must have no
   uncommitted changes.
5. Click **Bring Back**. The sheet says which branches moved forward.

Only the commits that this Mac does not have come back. A branch moves forward only, also
in a worktree that has it checked out. A bring back never overwrites work done on this Mac.
It stops, and changes nothing, when:

- a branch on this Mac has commits of its own that the server does not have. Merge or
  rebase on the server, or push and pull, then bring back again;
- a branch that must move is checked out in a folder on this Mac with uncommitted changes.
  Commit them or remove them, then bring back again.

## How it works

This Mac's host makes a `git bundle` of the branches, without the commits that the server
has, and a patch of the uncommitted changes. The patch is made with an index of its own, so
the index of your repository does not change. The window sends both to the server in parts
of 1 MB, over the connection it already has to the server through the control plane. It
does not decode a part: the text it reads from one host goes to the other as it is, and it
reads the next part while it sends this one. Thus the window holds about 2 MB of the send,
and the server's other messages wait for 1 MB at most. The
server fetches from the bundle, moves each branch forward (never back), checks out the
branch, applies the patch and adds the folder as a folder.

A bring back is the same in reverse: the server makes the bundle, without the commits that
this Mac has, and the patch. This Mac's host fetches from the bundle and moves each branch
forward. Where a branch is checked out, it moves with a fast-forward merge, so the files
there change with it.

A send that stops before its end (a sheet closed, a window that quit, a lost connection)
leaves its files on the hosts for a time. The next send removes each file that nothing
touched for an hour. A send or a bring back that stops at a check removes its files at once.
