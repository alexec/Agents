---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Have agents start by themselves, on a schedule or when another agent finishes, stops or asks for something.
---

# Set up a workflow

A workflow gives an agent a prompt by itself: on a schedule, or when something happens to
another agent in the same folder. This guide sets up one that starts a reviewer whenever
an agent finishes.

## Before you start

- A folder with a runtime that works in it. See [Add a folder](add-a-folder.md).
- For the full list of triggers and settings, see
  [Workflow triggers and actions](../reference/workflows.md).

## Steps

1. Ask an agent in the folder to write the workflow for you, in words. For example:

   ```text
   Add a workflow: whenever an agent in this folder finishes, start a new agent that
   reviews what it changed and lists anything that looks wrong. It should not change
   any files.
   ```

   The agent writes it as a file in the folder and it appears on the folder's page
   under **Workflows**. You can instead write the file yourself: a workflow is one
   Markdown file in the folder's `.agents/workflows` folder. The one above looks like
   this, saved as `.agents/workflows/review-finished-work.md`:

   ```markdown
   ---
   name: Review finished work
   on:
     - agent.finished
   agent: new
   permission-mode: plan
   ---

   Review what the agent that just finished changed, and list anything that looks
   wrong, with the file and line. Do not change any files. If the agent that finished
   was itself only reviewing, say so and finish.
   ```

   - `on` is what makes it run. Besides `agent.finished` there are `agent.stopped`,
     `agent.failed`, `agent.asked_permission`, `agent.asked_form`, `workflow.completed`,
     a `schedule` (on the hour or half hour, with optional hours and days), and any other
     name on [Events](../reference/events.md).
   - Only a few events can be narrowed: `branch.moved` by `branch`, and `person.away` and
     `person.back` by `why`. `branch.moved` is only raised for a branch an agent works on,
     never the default branch (#702); to run when a pull request lands, use the `github`
     server's `pr.merged`. To run when one agent's branch moves:

     ```yaml
     on:
       - branch.moved:
           branch: agents/fix-640
     ```

     The folder page then says *When a branch an agent works on moved; never the default
     branch (branch agents/fix-640)*. A list, such as `branch: [agents/fix-640, agents/fix-641]`,
     means any of them.
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
   - `hosts` is optional. Leave it out and every computer with this folder runs the
     workflow. To pin it to one computer, open its page and choose that computer under
     **Runs on**. The page writes the computer's id.
   - `when-done` is optional. Leave it out and every run stays in the list when it is
     done. `archive-allowed` lets a run with nothing to show archive itself, and `archive`
     archives every run that finishes done. The **When done** menu on its page writes it.
2. Open the folder's page and find the workflow under **Workflows**. Its line says what
   it does, such as *When an agent finishes, in a new agent*. A workflow an agent wrote,
   or one you wrote in another editor, shows a raised hand and **New — waiting for your
   OK**: it does not run until you approve it.

   On iPhone and iPad and on the web page, the same list is on the folder's page, and
   you can approve a waiting workflow on its page there too.
3. Click the workflow to open its page. Check what it will do and the settings it will
   start the agent with (**Runtime**, **Permission mode**, **Model**, **Effort**), change
   any you want there, then click **Approve**. You can also click **Approve** on the row.
4. To try it without waiting, click **Run now**. On iPhone and iPad, **Run now** is on
   the workflow's page too.

   A new agent starts, named after the workflow, and appears on the folder's page. The
   workflow's page lists it under **History** (**Recent runs** on iPhone and iPad). See
   [Read a workflow's page](read-a-workflows-page.md).
5. From now on, each time an agent in the folder finishes, the workflow starts a reviewer.

**When the file changes**

A workflow runs only as you approved it. If its file changes afterwards, whether an
agent edited it, you pulled a change or edited it outside Agents, its row says
**Changed since you approved it — waiting for your OK** and it does not run until you
approve it again. The same is true of each skill the workflow names as
`.agents/skills/<name>/SKILL.md`: what you approve is the workflow with those skills, and
**Review** shows their text under the workflow's. Changes you make on the workflow's page in Agents count as approved,
unless the workflow was already waiting. Workflows that existed before this version
were approved as they stood.

**One you only run by hand**

A workflow you only ever start yourself says `on: manual`, or has no `on:` at all, such as
"Set up a workflow, run only by hand, that drafts release notes from the commits since the
last tag." Nothing else runs it, and its row reads **By hand, with Run now**. See
[Run only by hand](../reference/workflows.md#run-only-by-hand).

**Pin it to the sidebar**

Pin a workflow you run often, and it sits in its folder's **Pinned** group, with the pinned
sessions, at the top of the folder in the sidebar: one click opens its page, and **Run
now** is there.

- On the Mac, right-click its row and choose **Pin**, swipe the row right with two fingers,
  or click **Pin** on its page. Drag it among the pinned workflows to order them.
- On iPhone and iPad, long-press its row for **Pin**, **Move Up** and **Move Down**, swipe
  it right, or tap the pin in its page's bar.
- On the web page, **Pin**, **Move Up** and **Move Down** are in the row's **···** menu, and
  **Pin** is on its page.

**Unpin** is in the same places. The pin is kept in the folder's `.agents/pins.json`, so it
lasts through a restart and every client sees it. Archiving a workflow unpins it, and
unarchiving it does not pin it again.

**Turn it off**

- Turn it off for a while: on the Mac, click **Turn Off** on its page, or right-click its
  row and choose **Turn Off**. On iPhone and iPad, switch off **Enabled** on its page, or
  long-press its row for **Turn Off**. On the web page, switch off **Enabled** on its page. It stays where it is, marked **Off**, none of its triggers run it, and
  **Run now** still does. Switch it back on to have it run again.
- Archive it: on the Mac, swipe the row left with two fingers, right-click it and choose
  **Archive**, or click **Archive** on its page. It stays listed under **Archived workflows** and
  does not run until you click **Unarchive**. The file is kept.
- Both write the workflow's own file: off adds `enabled: false` and archive adds
  `archived: true`, and turning it back on or unarchiving it takes the line out. That
  is a change in your folder you may commit, and it is how the choice reaches your other
  clones, Macs and servers. Commit it if they should have it too.
- To remove it for good, delete its file. **Show in Finder** on the row's menu finds it.

## Keep a long method in a skill

When a workflow's prompt grows past a few paragraphs, put the method in a skill and keep
the workflow slim (#1563). A person or an agent can then follow the same method by hand,
and you change the method without touching the workflow's triggers.

1. Write the method as a skill in the folder: `.agents/skills/<name>/SKILL.md`, with a
   `name` and a `description` that says when to use it. See
   [Share skills across agents](share-skills-across-agents.md).
2. Keep the workflow to its front matter, one or two lines about what it is for, its
   limits, and a line that names the skill. For example, `.agents/workflows/crash-reports.md`:

   ```markdown
   ---
   name: Crash reports
   on:
     - schedule:
         at: [":00"]
         between: "07:00-07:00"
   agent: new
   permission-mode: approve-for-me
   when-done: archive
   ---

   You read the crash reports this folder's apps wrote on this Mac since the last run,
   and file a GitHub issue for each distinct crash that is not already tracked. The
   issues are the handoff: you fix nothing.

   Follow the `crash-reports` skill (`.agents/skills/crash-reports/SKILL.md`) from its
   first step to its last. Its rules are the limits of this run. The note at the end of
   this prompt says why the run started.
   ```

3. Do not write the cause of the run into the file. The app adds a note at the end of
   every run's prompt that says why it started: the event and its details, the agent
   behind it, the schedule's time, **Run now**, or the agent that ran it (#1562). See
   [Workflow triggers and actions](../reference/workflows.md).

`.agents/workflows/release.md` and the review workflows in this repository have this shape.

**What you approve**

The app finds a skill in the workflow's text by its path, `.agents/skills/<name>/SKILL.md`.
It is not a field in the front matter. What you approve is the workflow together with each
skill it names, and **Review** shows the text of each skill under the workflow's. A change
to one of those skills makes the workflow wait for your OK again, as a change to its own
file does. A skill holds the method, so a changed skill changes what the run does.

The workflow does not run, and its page says why, when a skill it names:

- is not there, or cannot be read;
- is a link, or is in a folder that is a link;
- is outside the folder's `.agents/skills` folder, for example a name with `/` or `..`.

## Let an agent run a workflow

An agent can run a workflow once, as **Run now** does, with the `run` action of its
`manage_workflows` tool (#1526). This lets one agent hand a job to a workflow that already
has the right prompt and settings, such as a release agent that runs the review workflows.
Ask it in words, for example:

```text
Run the crash-reports workflow now, and tell me what it finds.
```

The agent gets the id of the session that the run started. It can then wait for that
session to finish, or read it.

An agent cannot run a workflow that:

- waits for your OK, or is archived;
- is turned off. **Run now** on its page still runs it, but an agent does not, because
  the off switch is yours;
- has `agent: triggering`, because nothing triggered it;
- would go past the chain limit of three. The run carries the chain depth of the agent
  that runs it, so workflows cannot run each other for ever.

When it cannot run, the agent is told why, and nothing starts. The run's prompt ends with a
note that names the agent that ran it, by its title and id. See
[Workflow triggers and actions](../reference/workflows.md) and
[Tools the app gives agents](../reference/agent-tools.md).

## If it doesn't work

A workflow that did not run says why on its row and its page, for example:

- **Queued — a run is still going, and it runs when that ends**: a trigger came while
  the last agent it started was working. It runs when that one finishes.
- **Did not run — 10 triggers are already queued for it**: triggers are coming faster
  than its runs finish. Ten wait at most.
- **Did not run — a run is still going**: you pressed **Run now** while a run was
  starting or already using the workflow's selected runtime. If a run is active on
  another runtime, select a runtime in the workflow and press **Run now** to retry there.
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
- [Read a workflow's page](read-a-workflows-page.md)
