---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Have agents start by themselves, on a schedule or when another agent finishes, stops or asks for something.
---

# Set up a workflow

A workflow gives an agent a prompt by itself: on a schedule, or when something happens to
another agent in the same project. This guide sets up one that starts a reviewer whenever
an agent finishes.

## Before you start

- A project with a runtime that works in it. See [Add a project](add-a-project.md).
- For the full list of triggers and settings, see [Reference](../reference/index.md).

## Steps

1. Ask an agent in the project to write the workflow for you, in words. For example:

   ```text
   Add a workflow: whenever an agent in this project finishes, start a new agent that
   reviews what it changed and lists anything that looks wrong. It should not change
   any files.
   ```

   The agent writes it as a file in the project and it appears on the project's page
   under **Workflows**. You can instead write the file yourself: a workflow is one
   Markdown file in the project's `.agents/workflows` folder. The one above looks like
   this, saved as `.agents/workflows/review-finished-work.md`:

   ```markdown
   ---
   name: Review finished work
   on:
     - agent-finished
   agent: new
   permission-mode: plan
   ---

   Review what the agent that just finished changed, and list anything that looks
   wrong, with the file and line. Do not change any files. If the agent that finished
   was itself only reviewing, say so and finish.
   ```

   - `on` is what makes it run. Besides `agent-finished` there are `agent-stopped`,
     `agent-asked-permission`, `agent-asked-form`, `workflow-completed`, a `schedule`
     (on the hour or half hour, with optional hours and days), and the pull request
     triggers in [Have an agent watch a pull request](watch-a-pull-request.md).
   - `agent` is who gets the prompt: `new` starts a fresh agent every time, `standing`
     keeps one agent for this workflow and prompts it again each time, and `triggering`
     prompts the agent that set it off.
   - Everything under the second `---` is the prompt, word for word. The agent it starts
     is also told which agent set it off and what that agent did.
   - `permission-mode`, `runtime`, `model` and `effort` are optional. The values are the
     runtime's own; `plan` is Claude's read-only mode. Leave them out to use the
     runtime's defaults.
2. Open the project's page and find the workflow under **Workflows**. Its line says what
   it does, such as *When an agent finishes, in a new agent*, and **Waiting for its
   trigger**.

   On iPhone and iPad the same list is on the project's page.
3. Click the workflow to open its page. Check the settings it will start the agent with
   (**Runtime**, **Permission mode**, **Model**, **Effort**) and change any you want there.
4. To try it without waiting, click **Run now**. On iPhone and iPad, **Run now** is on
   the workflow's page too.

   A new agent starts, named after the workflow, and appears on the project's page. The
   workflow's page lists it under **Recent runs**, with **Open the agent it started**.
5. From now on, each time an agent in the project finishes, the workflow starts a reviewer.

**Turn it off**

- Archive it: on the Mac, swipe the row left with two fingers, right-click it and choose
  **Archive**, or click **Archive** on its page. It stays listed under **Archived** and
  does not run until you click **Restore**. The file is kept.
- To remove it for good, delete its file. **Show in Finder** on the row's menu finds it.

## If it doesn't work

A workflow that did not run says why on its row and its page, for example:

- **Did not run — a run is still going**: the last agent it started has not finished.
- **Did not run — this chain is already 3 deep**: workflows set off by agents that
  workflows started stop after three steps, so a reviewer that finishes cannot set off
  reviews for ever. That is why the example's prompt tells a reviewer of a reviewer to
  stop at once.
- **Missed — the app was closed**: the time came while Agents was not running on the
  Mac, or the Mac was off.
- **Not yet supported**: the file names a trigger or `agent` value this version does not
  know. Check the spelling.
- A line naming a problem with the file itself, such as **The metadata does not say what
  makes this run**. Fix the file; the page updates as soon as it is saved.
