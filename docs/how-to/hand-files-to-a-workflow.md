---
diataxis: how-to
devices: [mac, iphone, ipad, browser, server]
description: Drop a file into a folder's drop box, and have a workflow pick it up and work on it.
---

# Hand files to a workflow

Each folder has a drop box: the folder `.agents/dropbox/` in the folder. A file that
arrives there raises the event `file.added`, and a workflow in that folder that watches
that path runs on it. This guide sets up a workflow that reviews every PDF or Markdown file dropped
into `dropbox/review/`, and leaves every other file alone.

## Before you start

- A folder. The drop box is a folder in it, wherever the folder lives: a folder on a
  server has its drop box on that server.
- Workflows in that folder are approved and on. See [Set up a workflow](set-up-a-workflow.md).

## Steps

1. Write the workflow, in `.agents/workflows/review-drops.md`:

   ```markdown
   ---
   name: Review what lands in the drop box
   on:
     - file.added:
         paths: [".agents/dropbox/review/*.pdf", ".agents/dropbox/review/*.md"]
   agent: new
   ---

   Read each dropped file and review it, then move it out of .agents/dropbox/, to
   reviewed/ at the folder's top.
   ```

   `paths` says which files the workflow takes: globs relative to the folder. `*` stays
   in one folder, and `**` reaches into folders, so `.agents/dropbox/review/**` takes
   everything under `review`. A file anywhere else in the drop box, such as
   `.agents/dropbox/notes/`, does not start it.

2. Put a file into `.agents/dropbox/review/`, from Finder, a script, `cp` or `scp`. Make
   the folder if it is not there.

   On the Mac, you can also drag files from Finder onto the folder's row in the sidebar,
   or onto any of its sessions' rows. They go into the top of the folder's drop box,
   never into a session's worktree, so a prompt that takes only `review` leaves them.
   To put them in a folder such as `review`, right click the folder's row,
   choose **Put Files in Drop Box…**, type the folder, then drag the files onto the
   sheet or press **Choose Files…**. A file sent from the Mac can be up to 25 MB; copy a
   bigger one into the folder in Finder. A folder dragged onto the list is added as a
   folder, as before.

   On the iPhone or iPad, touch and hold the folder in the list, choose **Put Files in
   Drop Box…**, type a folder such as `review` if you want one, then **Choose Files…**.

   On the web page, open the folder's menu (right click, or the menu key) and choose
   **Put Files in Drop Box…**, type a folder if you want one, choose files and press
   **Put in Drop Box**. You can also drag files onto a folder's or a session's row, which
   puts them at the drop box's top.

   From the phone or the web page, a file can be up to 900 KB, the most that crosses the
   link in one go.

3. Once the file has stopped changing for a moment, the workflow starts an agent. Its
   prompt ends with the event, including `paths`, the files that arrived together,
   relative to the folder, so the agent knows which files to read.

## What happens to the file

The app never moves or deletes a dropped file. The workflow's prompt says what to do with
it: leave it, move it or delete it.

- **A file dropped under a name already there replaces it, and fires nothing.** Neither
  does a file changed where it lies. To send a file again, drop it under a new name.
- **Moving a file to another folder in the drop box is an arrival there**, and runs a
  workflow whose `paths` match that folder. Have the agent move a file it is done with
  out of `.agents/dropbox/`.
- **Files already in the drop box when the workflow is read or turned on do nothing.**
  Only new arrivals fire.
- **A file still being written fires once, after it stops changing.**
- **Files that arrive together are one event**, and one run: `paths` lists them all.
- **`**` matches names starting with a dot too**, such as Finder's `.DS_Store`. Name the
  extensions, as above, to leave them out.
- **There is no size or rate limit**, and `.gitignore` does not apply. Whether to commit
  dropped files is up to the folder: add `.agents/dropbox/` to its `.gitignore` to keep
  them out of git.

## See also

- [Events](../reference/events.md): `file.added` and its details.
- [Workflow triggers and actions](../reference/workflows.md)
- [Set up a workflow](set-up-a-workflow.md)
