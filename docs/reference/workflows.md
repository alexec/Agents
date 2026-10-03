---
diataxis: reference
devices: [mac]
description: The workflow file format — every trigger, every setting, and the limits on what runs.
---

# Workflow triggers and actions

This page lists everything a workflow file can say: what makes it run, which agent runs
it, and how that agent runs.

A workflow is one Markdown file in the project's `.agents/workflows` folder. The file
name, without `.md`, is the workflow's id. The file starts with front matter between two
`---` lines, and everything under it is the prompt, sent to the agent as it is written:

```markdown
---
name: Morning build check
on:
  - schedule:
      at: [":00"]
      between: "09:00-09:00"
      days: [mon, tue, wed, thu, fri]
agent: new
permission-mode: plan
labels: [build, morning]
---

Check the build and say whether it is green.
```

| In the file | Values | What it means |
| --- | --- | --- |
| `name:` | Any text | The name shown on the project page. Without it, the name is made from the file name. |
| `on:` | One trigger, or a list of them | What makes the workflow run. Required. With a list, any one of them runs it. |
| `on:` `schedule` | `at:`, and optionally `between:` and `days:` | Runs at set times. **At** is a list of minutes past the hour, `":00"` or `":30"` and nothing else. **Between** is a range of hours such as `"09:00-18:00"`; without it, every hour. **Days** is a list of `mon`, `tue`, `wed`, `thu`, `fri`, `sat`, `sun`; without it, every day. A time missed while the Mac slept or the app was closed is not run later; the workflow's page says it was missed. |
| `on:` `agent-finished` | No settings | Runs when an agent in this project finishes a turn. |
| `on:` `agent-asked-permission` | No settings | Runs when an agent in this project asks for permission. |
| `on:` `agent-asked-form` | No settings | Runs when an agent in this project asks you to fill in a form. |
| `on:` `agent-stopped` | No settings | Runs when an agent in this project stops without finishing. |
| `on:` `workflow-completed` | Optionally `id:`, a workflow's id | Runs when that workflow's run finishes, or when any workflow's run finishes if there is no `id:`. |
| `on:` an event name, such as `branch.moved` or `custom.build_green` | Optionally the event's details, as filters | Runs when that event happens. Any name on [Events](events.md) works, or a subject with `.*`, such as `agent.*`, for all of its events. Under the name, list details to narrow it, such as `branch: main`. A detail can take a list, meaning any of them, such as `outcome: [done, nothing_to_do]`. A detail the event does not carry, or a value a detail cannot have, is an error in the file, naming the right ones. An event about this Mac runs matching workflows in every project. A name this version does not know is shown on the workflow's page and never runs. |
| `agent:` `new` | The default | Each run starts a new agent. |
| `agent:` `standing` | | Each run goes to the workflow's own agent, which keeps its conversation from run to run. |
| `agent:` `triggering` | | Each run goes to the agent that set it off. For an event, it is the agent the event is about, or the agent that published a `custom.` event. A schedule, or an event with no agent, has no such agent, so it does not run. |
| `permission-mode:` | One of the runtime's own modes, such as a read-only or plan mode | The mode the agent runs in. A workflow runs with nobody watching, so this is how to say it must not change anything. |
| `runtime:` | `claude`, `codex`, `gemini`, `antigravity`, `grok`, `copilot`, `cursor` | The runtime the agent runs on. Without it, Claude. A name this version does not know stops the workflow running, and its page names the runtimes it knows. A runtime it knows but that can't take an agent when the workflow runs (not installed, not signed in, or out of the pool) stops that run the same way: nothing starts, and the page says why and names the runtimes that can. See [Runtimes](runtimes.md). |
| `model:` | One of the runtime's models | The model the agent uses. Without it, the runtime's own default. |
| `effort:` | One of the runtime's levels, such as `low` or `high` | How hard the agent thinks. Without it, the runtime's own default. |
| `labels:` | A list of up to five names, each 1–24 characters | Each newly started workflow session gets these agent-owned labels. A standing or triggering run reusing an existing session keeps that session’s labels. |
| `options:` | Any other option the runtime offers, by its id, such as `fast: true` | Sets that option for the agent. |
| `enabled:` | `true` or `false` | Its **Enabled** switch. `false` is turned off: none of its triggers run it, and **Run now** still does. Without it, or with `true`, it is on. The switch, **Turn Off** and **Turn On** write this line and nothing else: off adds `enabled: false`, on takes the line out. So the switch goes wherever the file goes, to another clone or another Mac or server, and shows in a commit. An agent cannot turn on a workflow whose file says `false` unless an agent turned it off, on this Mac or server, and the file has not changed since; only you can. Anything else stops the workflow running, and its page says what is wrong. |
| `archived:` | `true` or `false` | Whether it is archived. **Archive** adds `archived: true` and **Bring Back** takes the line out, so it is archived wherever the file goes. See [Off and archived](#off-and-archived). Anything else stops the workflow running, and its page says what is wrong. |
| `cooldown:` | A length of time in minutes, hours or days, such as `15m`, `2h`, `1h30m` or `1d`; at least a minute | The least time from the start of one run to the start of the next. See [Cooldown](#cooldown). A value that is not a length of time stops the workflow running, and its page says what is wrong. |

For example, to start a new agent whenever `main` moves, or another agent publishes
`custom.build_green`:

```markdown
---
name: After the build
on:
  - branch.moved:
      branch: main
  - custom.build_green
agent: new
---

Deploy the docs, then say what you deployed.
```

To narrow by more than one value, give a list. This one runs when an agent labelled `bug`
finishes and is parked, and when the `nightly` workflow's agent ends `stuck` or
`partly_done`:

```markdown
---
name: Write up bug fixes
on:
  - agent.finished:
      labels: bug
      afterwards: park
  - workflow.completed:
      workflow: nightly
      outcome: [stuck, partly_done]
agent: new
---

Write up what the agent that set this off changed, for the release notes.
```

Every agent event carries the agent's `labels`, `runtime` and `started_by`, so
`agent.failed` with `runtime: [gemini, grok]` runs on a Gemini or Grok agent's failure.
The values each detail takes are on [Events](events.md).

A workflow never runs on an `agent.` event about its own agent: the agent doing its run,
the agent a `new` or `standing` workflow started, or a helper either of those started. So a
workflow on `agent.finished` runs once when another agent finishes, not again when its own
agent does. A `triggering` workflow's agent is only its own for the run: when you next
prompt that agent and it finishes, the workflow runs again. Waits still hear every event.

The older hyphenated names still work, and each answers to the events listed under
[Older trigger names](events.md#older-trigger-names). The pull-request triggers
(`pull-request-checks-failed`, `pull-request-review-comments` and
`pull-request-conflicts`) have been removed: a workflow that names one shows it on its
page and never runs on it. On a workflow's page, its latest run
shows the event that caused it, with a link to it on the Events page.

A setting the runtime does not offer stops the workflow running, rather than falling back
to a default. The workflow's page shows which values the runtime offers once it has been
used in this project.

A workflow does not run, and its page says why, when:

- a run of it is still going;
- it is archived;
- it is turned off. Unlike archived, this is recorded on its row, as **Did not run — it
  is turned off**, counted on one line however many times it is skipped. **Run now**
  still runs it. A workflow that is off says why first, unless you turned it off on
  this Mac or server: **Off: its file says enabled: false** (checked in that way, or
  turned off on another clone), **Off: written by an agent** (see below), or **Off: an
  agent turned it off**. The Mac, the phone and the web page say the same. While one
  that started off is still waiting for your OK, its page says both, so approving it is
  not mistaken for turning it on;
- its file is new, or has changed since you approved it, and you have not approved it.
  Its row and page say **waiting for your OK** and offer **Approve**. Approval is of the
  file as you saw it: a file that changes afterwards waits again. Changes made on the
  workflow's page in Agents count as approved unless the workflow was already waiting,
  and workflows that existed before this version were approved as they stood;
- it is approved but not one of the first ten approved workflows across every project,
  taken in order of project folder and then file name. Archiving one anywhere makes room;
  turning one off does not. See [Limits](#limits);
- it was set off by a chain of workflows already three deep;
- the day's spending limit has been reached;
- the project folder is not there;
- its `agent:` is `triggering` and the agent it would have resumed is gone, or nothing
  set it off;
- its cooldown has not ended, or a run is still going and it has one. This trigger is
  held, not dropped, and runs once when the cooldown ends (see [Cooldown](#cooldown));
- the file cannot be read, or names a trigger or `agent:` value this version does not
  know. The page says what is wrong with the file.

On the Mac, each workflow on the project page has **Open**, **Run now** (**Approve**
while it is waiting for your OK), **Turn Off** (**Turn On** once off), **Archive**
(**Bring Back** once archived) and **Show in Finder**. Its page has the **Enabled** switch
beside **Run now**, and a **Triggers** section listing each trigger on its own line: the
filters on it, whether it listens in this project or on the whole Mac or server, which
agent a `triggering` run resumes, when a schedule is next due, and a trigger this
version does not know marked **Unknown**. Under them it says when the workflow last ran
and what set it off. A file that cannot be read still lists the triggers it could read.

## Cooldown

A workflow on a busy trigger, such as `agent.finished`, can run many times a day. A
`cooldown:` limits how often:

```markdown
---
name: Close landed issues
on:
  - agent.finished
cooldown: 15m
---
```

- The cooldown counts from the **start** of the last run.
- A trigger that comes inside the cooldown, or while a run is still going, is **held**,
  not dropped. When the cooldown ends and no run is going, the workflow runs **once**,
  for the latest held trigger. A burst of triggers gives one run, and that run is told
  about the last of them.
- Each held trigger is recorded: on its event, on the Events page, and on the workflow's
  row as **Waiting — it is cooling down until 14:32, and runs once then**, counted on one
  line. A held trigger is not put on the log as `workflow.refused`.
- A schedule that comes due inside the cooldown is held the same way.
- **Run now** is not held. It runs at once, even inside the cooldown, and starts the
  cooldown again. It still waits for a run that is going.
- A trigger set off by a chain already three deep is refused, not held.
- Turning the workflow off or archiving it drops the held trigger. A held trigger survives
  the app restarting.
- Without `cooldown:`, every trigger runs it, one run at a time, as before.

The **Triggers** section of the workflow's page says the cooldown, when it ends, and
whether a trigger is held for then. Its menu changes the cooldown by rewriting
`cooldown:` in the file. The project page's row, the phone and the web page say "at most
once every 15 minutes" after the triggers.

## Limits

Two limits, both fixed:

- **At most three workflows waiting for approval in one project.** Approved workflows do
  not count, so a project may have as many approved workflows as the next limit allows.
  An agent writing a fourth with `manage_workflows`, or changing an approved one so it
  would wait, is refused: *Approve or remove one of the 3 workflows waiting for approval
  first.* A file that arrives in `.agents/workflows/` some other way, such as a merge or a
  copy, is still listed, but past the first three waiting (in order of file name) it is
  inert: its row says *This project already has 3 workflows waiting for approval. Approve
  or remove one of the 3 workflows waiting for approval first*, and it has no
  **Approve** until one of the three ahead of it is approved, archived or removed.
- **At most ten approved workflows run, across every project.** Past that, a workflow is
  listed and says *10 workflows are already running, across every project*. Archiving
  one anywhere makes room.

Archived workflows count towards neither. Turned-off ones still count.

## Off and archived

Both stop a workflow running, and both are kept in the workflow's own file, as
`enabled: false` and `archived: true`, so they go with the project to every clone, Mac
and server. **Turning a workflow off or archiving it changes a file in your project,
which you may commit.** Each writes its one line and nothing else, and doing the
opposite takes the line out again, leaving the file as it was. A workflow you had
approved stays approved: the app made the change you asked for, not a new workflow.
One still waiting for your OK still waits.

What stays on this Mac or server, and is not written into the project, is the
workflow's history there: its runs and outcomes, a held trigger, the agent a
`standing` workflow keeps, what you have approved, and who turned it off. That last is
why a workflow turned off on another clone says **Off: its file says enabled: false**
here.

They differ in what else they do:

| | Turned off | Archived |
| --- | --- | --- |
| Where it is listed | In its place, marked **Off** | Under **Archived workflows** |
| Its triggers | Do not run it; each one skipped is counted on its row | Do not run it; nothing is recorded |
| **Run now** | Runs it, to try it | Refuses |
| The [limits](#limits) | Still counts, so turning it off and on again moves nothing | Frees its place |
| Turned back on by | **Enabled**, **Turn On**, the phone, or an agent if an agent turned it off (not one an agent wrote, or one whose file says `enabled: false`) | **Bring Back** |

A new workflow an agent writes with `manage_workflows` starts turned off, whatever its
file says, so you turn it on knowingly once you have approved it: the app writes
`enabled: false` into it, and an agent cannot turn it on. An agent changing a workflow
that already exists through `manage_workflows` leaves its `enabled:` and `archived:`
lines as they were, whatever its new text says. A file you or an agent put in
`.agents/workflows/` some other way, such as a merge or an edit, is on unless it says
`enabled: false`, and archived only if it says `archived: true`; a change to it waits
for your OK like any other.

Before this version, the switch and the archive were kept on the Mac or server rather
than in the file. The first start of this version writes each one into its workflow's
file once, so a project's files may change then.

Off is for a workflow you still use but want quiet for a while: while a test is flaky,
or while you are away. Archive is for one you are putting away.

## See also

- [Set up a workflow](../how-to/set-up-a-workflow.md)
- [Have an agent wait for something](../how-to/wait-for-something.md)
- [Events](events.md)
- [Tools the app gives agents](agent-tools.md)
