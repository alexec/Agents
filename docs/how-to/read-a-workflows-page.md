---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Open a workflow's page, see whether it runs and why not, see what each run did and why it started, and run it now.
---

# Read a workflow's page

Each workflow has a page of its own. The page tells you whether the workflow runs, and if
not, why not. It lists the agents it started, and shows how the workflow is set up. From
the page you can also run the workflow now.

The page has two halves, **Activity** and **Configuration** (#868). **Activity** answers
"does it run, and what did it do?". **Configuration** answers "what does it do, when, and
where?". You usually need only one of them at a time, so the page shows one at a time.

## Before you start

- A folder with a workflow in it. See [Set up a workflow](set-up-a-workflow.md).

## Open the page

- **On the Mac:** click the workflow under **Workflows** in its folder in the sidebar, or
  under **Workflows** on the folder's page. You can also right-click its row and choose
  **Open**.
- **On iPhone and iPad:** tap the workflow under **Workflows** in its folder in the
  sidebar, or on the folder's page.
- **On the web page:** click the workflow under **Workflows** in its folder in the sidebar.

A workflow you pinned is also in its folder's **Pinned** group, at the top.

The page opens on **Activity**. To see the other half, choose **Configuration** in the
switch under the title. The page keeps your choice when you open another workflow, so you
can compare the runs of two workflows without a switch each time.

## Read Activity

**Status** has one line for each thing that decides whether the workflow runs. The most
important line is first: what stops it, then what it does now, then when it runs next.
For example:

- That it waits for your OK, because it is new or it changed since you approved it. It
  does not run until you approve it.
- Whether it is on or off, and why: what its file says, or who turned it off.
- **Running now**, with **Open the agent** to go to the run.
- **1 trigger queued**, or **Cooling down until 14:30**.
- A line that starts **Did not run**, and says why the last trigger did not run, such as
  that a run is still going.
- **Next run tomorrow**, **Runs only by hand, with Run now**, or **No next run**.

A line that needs you is in the attention colour. A problem with the file is in red, and
the file's text is under it, so you can see the line that is wrong.

Under Status are the runs: **History** on the Mac and the web page, **Recent runs** on
iPhone and iPad. Each run is the session it started, newest first. Click or tap one to
open it. Three show at first. **Show more** shows more.

On the Mac and the web page, a line above the runs says when it last ran and why, such as
**Last ran 5 minutes ago, by hand, with Run now.** On iPhone and iPad this line is under
**Triggers** on **Configuration**.

## See why a run started

Every run is told why it started, in a note at the end of its prompt (#1582). Open the run,
and read the first prompt in its chat. It ends with a note such as:

```text
(You were started by the workflow "Morning build check" because of its schedule: the 09:00 run.)
```

The note names the cause:

- an event, with its sentence and its details;
- the agent that set it off, and what that agent did;
- the time of the schedule's run;
- **Run now**, as "the person ran it by hand";
- an agent that ran it with `manage_workflows`, by its title and id.

The agent reads the same note, so it knows what to act on. You read it to see why a run
you did not expect started. The workflow's file does not change. For the full list, see
[Workflow triggers and actions](../reference/workflows.md).

## Read Configuration

**Configuration** shows the file as the app reads it:

- **What it does**: the file, the runtime, who gets the prompt (such as **Starts a new
  agent each run**), the prompt word for word, and the settings the agent starts with.
- **Triggers**: one line for each trigger, with its filters. It also has **Cooldown** and
  **When done**.
- **Runs on**: which computers run it. **Every host** is the default.
- **From a later version**: lines of the file that this version does not know. The app
  keeps them as they are.

You can change the runtime, the permission mode, the model, the effort, the labels, the
cooldown, **When done** and **Runs on** here. Each change writes the workflow's file. You
cannot change the triggers or the prompt here: they are the author's, so edit the file.

On iPhone and iPad, the runtime and the other settings are under **Settings**, and the
labels under **Labels**. Each setting has a row of its own, because three menus side by
side do not fit a phone.

## Run it now

1. Open the workflow's page.
2. Run it:
   - **On the Mac:** click **Run Now** in the window's toolbar.
   - **On iPhone and iPad:** tap **Run now** under the title.
   - **On the web page:** click **Run Now** under the title.

The button says **Running…** while a run goes, and you cannot press it again until the run
ends. A run you start this way is not queued.

**Run now** also runs a workflow that is turned off, because off stops its triggers, not
you. It does not show while the workflow waits for your OK: **Approve** and **Deny on This
Host** are in its place. **Approve** first, and then **Run now** comes back.

## The other actions

| Action | Mac (toolbar) | iPhone and iPad | Web page |
| --- | --- | --- | --- |
| Turn it off or on | **Turn Off** or **Turn On** | The **Enabled** switch | The **Enabled** switch |
| Pin to the sidebar | **Pin** or **Unpin** | The pin in the bar | **Pin** or **Unpin** |
| Archive | **Archive** | **Archive** in the bar | **Archive** |
| Delete the file | **Delete…** | **Delete…** in the bar | **Delete…** |

**Archive** goes back to the folder. Off and archived are lines in the workflow's own
file (`enabled: false`, `archived: true`), and the page says so under the title. Commit
the file if your other clones should have the change too.

## If it doesn't work

- **A run did not start.** Read **Status** on **Activity**. The line about the last
  trigger says why, such as that the chain is already 3 deep. The reasons
  are in [Set up a workflow](set-up-a-workflow.md#if-it-doesnt-work).
- **A run started but did not finish.** Open it from **History** or **Recent runs**. Its
  status in the chat says how it ended: **Stuck**, **Partly done** or **Unexpected stop**.
- **The page says This workflow is no longer there.** Its file was removed or renamed.
  On the Mac, the page then goes back to the folder.
- **Run now is not there.** The workflow waits for your OK, or it is archived. Approve it,
  or click **Unarchive**.

## See also

- [Set up a workflow](set-up-a-workflow.md)
- [Workflow triggers and actions](../reference/workflows.md)
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md)
- [Gestures on the iPhone and iPad](../reference/remote-gestures.md)
