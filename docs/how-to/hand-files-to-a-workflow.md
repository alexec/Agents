---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Drop a file into a project's drop box, and have a workflow pick it up and work on it.
---

# Hand files to a workflow

Each project has a drop box: the folder `.agents/dropbox/` in the project. A file that
arrives there raises the event `dropbox.file_added`, and a workflow in that project can
run on it. This guide sets up a workflow that reviews every PDF or Markdown file dropped
into `dropbox/review/`.

## Before you start

- A project. The drop box is a folder in it, wherever the project lives: a project on a
  server has its drop box on that server.
- Workflows in that project are approved and on. See [Set up a workflow](set-up-a-workflow.md).

## Steps

1. Write the workflow, in `.agents/workflows/review-drops.md`:

   ```markdown
   ---
   name: Review what lands in the drop box
   on:
     - dropbox.file_added:
         folder: review
         extension: [pdf, md]
   agent: new
   ---

   Read the dropped file and review it. Move it to .agents/dropbox/done/ when finished.
   ```

   `folder` is where the file is inside the drop box: `review` for
   `.agents/dropbox/review/`, and empty for the drop box's top. `extension` is the
   file's extension in lower case, without the dot. Leave either out to take every file.

2. Drop a file into `.agents/dropbox/review/`, from Finder, a script, `cp` or `scp`. Make
   the folder if it is not there.

3. Once the file has stopped changing for a moment, the workflow starts an agent. Its
   prompt ends with the event, including `path`, the file's full path, so the agent knows
   which file to read.

## What happens to the file

The app never moves or deletes a dropped file. The workflow's prompt says what to do with
it: leave it, move it or delete it.

- **A file dropped under a name already there replaces it, and fires again.** So does a
  file changed where it lies, which an agent editing it would do. Have the agent move a
  file out of the folder its workflow watches before it changes it.
- **Moving a file to another folder in the drop box is an arrival there.** A workflow
  that watches `review` does not hear a file moved to `done`; one with no `folder` does.
- **Files already in the drop box when the app starts do nothing.** Only new arrivals
  fire.
- **A file still being written fires once, after it stops changing.**
- **Names starting with a dot are passed over**, so a copy's temporary file and Finder's
  `.DS_Store` never fire.
- **There is no size or rate limit**, and `.gitignore` does not apply. Whether to commit
  dropped files is up to the project: add `.agents/dropbox/` to its `.gitignore` to keep
  them out of git.

## See also

- [Events](../reference/events.md): `dropbox.file_added` and its details.
- [Workflow triggers and actions](../reference/workflows.md)
- [Set up a workflow](set-up-a-workflow.md)
