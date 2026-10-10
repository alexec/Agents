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
- For the full list of triggers and settings, see
  [Workflow triggers and actions](../reference/workflows.md).

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
     (on the hour or half hour, with optional hours and days), and any name on
     [Events](../reference/events.md).
   - Only a few events can be narrowed: `branch.moved` by `branch`, and `person.away` and
     `person.back` by `why`. To run when `main` moves:

     ```yaml
     on:
       - branch.moved:
           branch: main
     ```

     The project page then says *When a branch moved: the default branch, or one an agent
     works on (branch main)*. A list, such as `branch: [main, develop]`, means any of them.
     Any other detail under an event is an error in the file. To act only on some agents,
     such as bug fixes, say which in the prompt: the agent it starts is told which agent
     set it off, and its labels.
   - `agent` is who gets the prompt: `new` starts a fresh agent every time, `standing`
     keeps one agent for this workflow and prompts it again each time, and `triggering`
     prompts the agent that set it off.
   - Everything under the second `---` is the prompt, word for word. The agent it starts
     is also told which agent set it off and what that agent did.
   - `permission-mode`, `runtime`, `model` and `effort` are optional. The values are the
     runtime's own; `plan` is Claude's read-only mode. Leave them out to use the
     runtime's defaults.
   - `hosts` is optional. Leave it out and every computer with this project runs the
     workflow. To pin it to one computer, open its page and choose that computer under
     **Runs on**. The page writes the computer's id.
   - `when-done` is optional. Leave it out and every run stays in the list when it is
     done. `archive-allowed` lets a run with nothing to show archive itself, and `archive`
     archives every run that finishes done. The **When done** menu on its page writes it.
2. Open the project's page and find the workflow under **Workflows**. Its line says what
   it does, such as *When an agent finishes, in a new agent*. A workflow an agent wrote,
   or one you wrote in another editor, shows a raised hand and **New — waiting for your
   OK**: it does not run until you approve it.

   On iPhone and iPad the same list is on the project's page, and a waiting workflow says
   **waiting for your OK on the Mac**. You approve it on the Mac.
3. Click the workflow to open its page. Check what it will do and the settings it will
   start the agent with (**Runtime**, **Permission mode**, **Model**, **Effort**), change
   any you want there, then click **Approve**. You can also click **Approve** on the row.
4. To try it without waiting, click **Run now**. On iPhone and iPad, **Run now** is on
   the workflow's page too.

   A new agent starts, named after the workflow, and appears on the project's page. The
   workflow's page lists it under **Recent runs**, with **Open the agent it started**.
5. From now on, each time an agent in the project finishes, the workflow starts a reviewer.

**When the file changes**

A workflow runs only as you approved it. If its file changes afterwards, whether an
agent edited it, you pulled a change or edited it outside Agents, its row says
**Changed since you approved it — waiting for your OK** and it does not run until you
approve it again. Changes you make on the workflow's page in Agents count as approved,
unless the workflow was already waiting. Workflows that existed before this version
were approved as they stood.

**One you only run by hand**

A workflow you only ever start yourself says `on: manual`, or has no `on:` at all, such as
"Set up a workflow, run only by hand, that drafts release notes from the commits since the
last tag." Nothing else runs it, and its row reads **By hand, with Run now**. See
[Run only by hand](../reference/workflows.md#run-only-by-hand).

**Pin it to the sidebar**

Pin a workflow you run often, and it sits in its project's **Pinned** group, with the pinned
sessions, at the top of the project in the sidebar: one click opens its page, and **Run
now** is there.

- On the Mac, right-click its row and choose **Pin**, swipe the row right with two fingers,
  or click **Pin** on its page. Drag it among the pinned workflows to order them.
- On iPhone and iPad, long-press its row for **Pin**, **Move Up** and **Move Down**, swipe
  it right, or tap the pin in its page's bar.
- On the web page, **Pin**, **Move Up** and **Move Down** are in the row's **···** menu, and
  **Pin** is on its page.

**Unpin** is in the same places. The pin is kept in the project's `.agents/pins.json`, so it
lasts through a restart and every client sees it. Archiving a workflow unpins it, and
bringing it back does not pin it again.

**Turn it off**

- Turn it off for a while: switch off **Enabled** on its page, or right-click its row and
  choose **Turn Off**. On iPhone and iPad, the switch is on its page and **Turn Off** is on
  a long press. It stays where it is, marked **Off**, none of its triggers run it, and
  **Run now** still does. Switch it back on to have it run again.
- Archive it: on the Mac, swipe the row left with two fingers, right-click it and choose
  **Archive**, or click **Archive** on its page. It stays listed under **Archived workflows** and
  does not run until you click **Bring Back**. The file is kept.
- Both write the workflow's own file: off adds `enabled: false` and archive adds
  `archived: true`, and turning it back on or bringing it back takes the line out. That
  is a change in your project you may commit, and it is how the choice reaches your other
  clones, Macs and servers. Commit it if they should have it too.
- To remove it for good, delete its file. **Show in Finder** on the row's menu finds it.

## If it doesn't work

A workflow that did not run says why on its row and its page, for example:

- **Queued — a run is still going, and it runs when that ends**: a trigger came while
  the last agent it started was working. It runs when that one finishes.
- **Did not run — 10 triggers are already queued for it**: triggers are coming faster
  than its runs finish. Ten wait at most.
- **Did not run — a run is still going**: you pressed **Run now** while it was running.
- **Did not run — this chain is already 3 deep**: workflows set off by agents that
  workflows started stop after three steps, so a reviewer that finishes cannot set off
  reviews for ever. That is why the example's prompt tells a reviewer of a reviewer to
  stop at once.
- **Missed — the app was closed**: the time came while Agents was not running on the
  Mac, or the Mac was off.
- **Did not run — it is waiting for your OK**: the file is new or has changed since you
  approved it. Open it, read it, and click **Approve**.
- **… changed after you looked at it, so it was not approved**: the file changed between
  your opening it and clicking **Approve**. Look at it again and approve what you see.
- **Not yet supported**: the file names a trigger or `agent` value this version does not
  know. Check the spelling.
- A line naming a problem with the file itself, such as **The metadata does not say what
  makes this run**. Fix the file; the page updates as soon as it is saved.

## See also

- [Workflow triggers and actions](../reference/workflows.md)
- [Events](../reference/events.md)
- [Have an agent wait for something](wait-for-something.md)
