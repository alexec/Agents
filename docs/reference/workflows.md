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
| `on:` | One trigger, or a list of them | What makes the workflow run. With a list, any one of them runs it. |
| `on:` `manual` | No settings | Nothing runs it but **Run now**, on its page or its row. Leaving `on:` out says the same. Its row reads "By hand, with Run now". See [Run only by hand](#run-only-by-hand). |
| `on:` `schedule` | `at:`, and optionally `between:` and `days:` | Runs at set times. **At** is a list of minutes past the hour, `":00"` or `":30"` and nothing else. **Between** is a range of hours such as `"09:00-18:00"`; without it, every hour. **Days** is a list of `mon`, `tue`, `wed`, `thu`, `fri`, `sat`, `sun`; without it, every day. A time missed while the Mac slept or the app was closed is not run later; the workflow's page says it was missed. |
| `on:` an event name, such as `branch.moved` or `custom.build_green` | Optionally the event's details, as filters | Runs when that event happens. Any name on [Events](events.md) works, or a subject with `.*`, such as `agent.*`, for all of its events. Under the name, list its filters to narrow it: `branch` on `branch.moved`, such as `branch: main`, and `why` on `person.away` and `person.back`. A filter can take a list, meaning any of them, such as `branch: [main, develop]`. Any other key, or a value a filter cannot have, is an error in the file, naming the right ones; the workflow never runs until it is fixed. An event about this Mac runs matching workflows in every project. A name this version does not know is shown on the workflow's page and never runs. |
| `on:` a server's event, such as `checks.failed` | Optionally `server:`, and the event's own filters | Runs when an MCP server reports that event. Its name is `noun.verbed`, with no prefix, as the server names it. Without `server:`, it hears every MCP server this project can use that offers the name, including one added later. `server:` narrows it to one server's name, or a list of names. Every other key is the event's own filter, sent to the server as it is: a list is a list argument, not "any of". A filter the event doesn't take, or a value of the wrong type, is an error on the workflow's page, naming the filters it takes. A name whose noun is one of the app's subjects, such as `branch.created`, is never a server's event. See [Events from MCP servers](events.md#events-from-mcp-servers). |
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
| `hosts:` | A list of machine ids | Which computers run it. Without it, or with an empty list, every host that has the project runs it and lists it. With ids, only those hosts do, on a schedule, on an event, or from **Run now**. An id is the computer's: a Mac's hardware UUID, or on Linux the contents of `/etc/machine-id`. The host name is used only when neither of those exists. The workflow's page offers the computers it knows by the names already on screen and writes the id, so renaming a computer does not unpin the workflow. A value that is not a list of ids stops the workflow running, and its page says what is wrong. |
| `when-done:` | `keep`, `archive-allowed` or `archive` | What a run may do with its session when it is done. Without it, `keep`: every run stays in the list. `park`, the word before #584, is read as `keep`. See [When a run is done](#when-a-run-is-done). Anything else stops the workflow running, and its page says what is wrong. |

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

To start a new agent for each file dropped into the project's `.agents/dropbox/` (see
[Hand files to a workflow](../how-to/hand-files-to-a-workflow.md)):

```markdown
---
name: Review what lands in the drop box
on:
  - dropbox.file_added
agent: new
---

If the dropped file is not a PDF or Markdown file, leave it and stop. Otherwise read it and
review it, then move it out of .agents/dropbox/, to reviewed/.
```

An arrival can't be narrowed by its folder or extension, so the prompt says which files to
leave, and a file the agent is done with leaves the drop box: moved to a folder inside it, it
would arrive again.

A run started by an event no agent is behind, such as this one, is told the event at the end of
its prompt, details and all, so the agent reads the file's `path` there.

Only `branch` on `branch.moved` and `why` on `person.away` and `person.back` narrow an
event (see [Names and filters](events.md#names-and-filters)). To narrow by more than one
value, give a list. This one runs when `main` or a `release/` branch you name moves:

```markdown
---
name: Check the release branches
on:
  - branch.moved:
      branch: [main, release/2.0]
agent: new
---

Check that the branch named in the event builds, and say what broke if it doesn't.
```

To run a check once a batch of agents is done, rather than after each one, use
`project.idle`. It runs once the last agent in the project has stopped, and its own agent
finishing does not set it off again:

```markdown
---
name: Check the batch
on:
  - project.idle
agent: new
---

Every agent here has stopped. For each agent in the event's ids, check that what it said it
did landed: its branch merged, its checks green. Remove worktrees whose branch is on main.
```

To run on an MCP server's event, name it as the server does, with its filters under it.
With GitHub and GitLab both set up and offering `pull_request.opened`, the first trigger
below hears either, and the event's `server` detail says which; the other two hear one
server each, with that server's own filter:

```markdown
---
name: Review new pull requests
on:
  - pull_request.opened
  - pull_request.opened:
      server: github
      repo: alexec/Agents
  - pull_request.opened:
      server: gitlab
      project: alexec/agents
agent: new
permission-mode: plan
---

Review the pull request in the event's data, and list anything that looks wrong.
```

Under **Triggers**, the workflow's page shows a line for each server a trigger hears: when
the server was last asked and when the last event came, or why not. See
[Start a workflow from an MCP event](../how-to/start-a-workflow-from-an-mcp-event.md).

A `new` or `standing` run set off by an event no agent is behind, such as `machine.disk_low`,
is told the event at the end of its prompt: its sentence and every detail, so the agent can
act on `level: critical` without looking it up.

Every agent event carries the agent's `labels`, `runtime` and `started_by`, so
`agent.failed` with `runtime: [gemini, grok]` runs on a Gemini or Grok agent's failure.
The values each detail takes are on [Events](events.md).

A workflow never runs on an `agent.` event about its own agent: the agent doing its run,
the agent a `new` or `standing` workflow started, or a helper either of those started. So a
workflow on `agent.finished` runs once when another agent finishes, not again when its own
agent does. A `triggering` workflow's agent is only its own for the run: when you next
prompt that agent and it finishes, the workflow runs again. Waits still hear every event.

The hyphenated names from before events (`agent-finished`, `agent-asked-permission`,
`agent-asked-form`, `agent-stopped` and `workflow-completed`) and the pull-request
triggers (`pull-request-checks-failed`, `pull-request-review-comments` and
`pull-request-conflicts`) have been removed. A workflow that names one shows it on its
page and never runs on it; for a hyphenated name, the page says which event to use, such
as "Did you mean agent.finished?". `manage_workflows` will not write one, and
`wait_for_event` will not wait for one, and both name the event to use. On a workflow's page, its latest run
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
- you denied it on this Mac or server. See [Approve, Deny and Archive](#approve-deny-and-archive);
- it is approved and on, but not one of the first ten (or the number you set) approved
  workflows turned on across every project, taken in order of project folder and then
  file name. Turning one off or archiving one anywhere makes room. See [Limits](#limits);
- it was set off by a chain of workflows already three deep;
- the day's spending limit has been reached;
- the project folder is not there;
- its `agent:` is `triggering` and the agent it would have resumed is gone, or nothing
  set it off;
- its cooldown has not ended, or a run is still going and it has one. This trigger is
  held, not dropped, and runs once when the cooldown ends (see [Cooldown](#cooldown));
- ten triggers are already queued behind a run that is going (see
  [One run at a time](#one-run-at-a-time));
- the file cannot be read, or names a trigger or `agent:` value this version does not
  know. The page says what is wrong with the file.

On the Mac, each workflow on the project page has **Open**, **Run now** (**Approve** and
**Deny on This Host** while it is waiting for your OK), **Turn Off** (**Turn On** once off), **Archive**
(**Bring Back** once archived) and **Show in Finder**. Its page has the **Enabled** switch
beside **Run now**, and a **Triggers** section listing each trigger on its own line: the
filters on it, whether it listens in this project or on the whole Mac or server, which
agent a `triggering` run resumes, when a schedule is next due, and a trigger this
version does not know marked **Unknown**. Under them it says when the workflow last ran
and what set it off. A file that cannot be read still lists the triggers it could read.

## Run only by hand

A workflow you only ever start yourself says `on: manual`, or has no `on:` at all.
Nothing else starts it: it runs when you press **Run now**. Pin it to the sidebar to keep
it one click away.

```markdown
---
name: Release notes
on: manual
agent: new
permission-mode: plan
---

Draft release notes from the commits since the last tag.
```

## One run at a time

A workflow runs once at a time. A trigger that comes while a run is going is **queued**,
not refused, and runs when that run ends:

- Each queued trigger runs on its own, oldest first, one after another. Each run is told
  its own event, with that event's details (and a server's data, for a server's event),
  so two failed checks for two pull requests give two runs, one for each.
- Its event reads **Queued for** the workflow on the Events page until its turn, and
  **Fired** from then on. The workflow's row and page say how many are queued.
- At most ten wait. One more is refused, as **Did not run — 10 triggers are already
  queued for it**, and that refusal is put on the log as `workflow.refused` with reason
  `queue_full`. A queued trigger is not.
- The queue survives the app restarting. Turning the workflow off or archiving it drops
  the queue, and each event it held says why.
- A trigger set off by a chain already three deep is refused, not queued.
- **Run now** is not queued: it says **a run is still going**, so you can try again.
- A workflow with a `cooldown:` does not queue. It holds the latest trigger and runs once
  for it (see [Cooldown](#cooldown)): a cooldown is there to make a burst one run, and
  queueing each trigger would undo it.

## When a run is done

Every run leaves a session behind. A workflow that runs often, such as a nightly check,
can put its runs away itself with `when-done:`. You set it, not the agent, as an agent
that starts a helper decides what becomes of it.

| Value | What happens |
|---|---|
| `keep` | The default, **Keep each run**. Every run stays in the list when it is done. A run may ask you to archive it. |
| `archive-allowed` | A run that finishes **Complete** or **Nothing to do** may archive itself, with `request_archive` or `archive_agent` and no id, when there is nothing for you to look at. It is told it may. Otherwise it stays. |
| `archive` | A run that finishes **Complete** or **Nothing to do** is archived, whatever the agent asks. |

- A run that ends **Waiting on your answer**, **Partly done**, **Stuck** or **Blocked** is
  never archived.
- Only the run's own turn counts. A run is not archived if you send it something before
  it finishes, or if it ends without saying how it went.
- An archived run says so in its conversation, and is still listed with the workflow's
  runs. Its worktree is cleaned up as when you archive a session.
- A `triggering` workflow prompts somebody else's agent, so `when-done:` does nothing
  for it, and its page does not offer the menu.
- Sessions you start can never archive themselves.

The **Triggers** section of the workflow's page has a **When done** menu that writes this
line. **Keep each run** takes it out.

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
- Without `cooldown:`, every trigger runs it, one run at a time, each queued behind the
  last (see [One run at a time](#one-run-at-a-time)).

The **Triggers** section of the workflow's page says the cooldown, when it ends, and
whether a trigger is held for then. Its menu changes the cooldown by rewriting
`cooldown:` in the file. The project page's row, the phone and the web page say "at most
once every 15 minutes" after the triggers.

## Limits

Two limits:

- **At most three workflows waiting for approval in one project.** Approved workflows do
  not count, so a project may have as many approved workflows as the next limit allows.
  An agent writing a fourth with `manage_workflows`, or changing an approved one so it
  would wait, is refused: *Approve or remove one of the 3 workflows waiting for approval
  first.* A file that arrives in `.agents/workflows/` some other way, such as a merge or a
  copy, is still listed, but past the first three waiting (in order of file name) it is
  inert: its row says *This project already has 3 workflows waiting for approval. Approve
  or remove one of the 3 workflows waiting for approval first*, and it has no
  **Approve** until one of the three ahead of it is approved, archived or removed.
- **At most ten approved workflows turned on run, across every project.** Ten is the
  default; set another number, from 1 to 50, in **Settings ▸ Cost ▸ The most workflows
  that may run** on the Mac. Only you can: agents can't, through the app's tools. It is
  kept by this Mac, outside every project, and copied to each server, which counts its
  own. Past it, a workflow is listed and says *10 workflows are already running, across
  every project. Turn one off or archive one, in any project, to let it run*, with the
  number in force. Turning one on when they are all taken is refused with the same words,
  and it stays off. A change takes effect at once: raising it lets the ones past it run
  from their next trigger, and lowering it stops the last ones, in the same order as
  ever, from their next trigger; a run already going finishes.

Archived workflows count towards neither, and nor do ones denied on this Mac or server.
Turned-off ones take no place among the ones that run; one waiting for approval counts
towards the three waiting whether it is on or off.

## Approve, Deny and Archive

A workflow waiting for your OK offers three answers, on the Mac, the phone and the web
page:

| | Meaning | Where it is kept |
| --- | --- | --- |
| **Approve** | Yes, run here | This Mac or server, outside the project |
| **Deny on This Host** | Don't run here | This Mac or server, beside the approval. Not in the workflow's file |
| **Archive** | Don't run anywhere | The workflow's file, as `archived: true` |

Deny is of the file as you saw it, the same way Approve is: a later change to the file
waits for your OK again. Other Macs and servers are untouched: they still see it waiting,
and any of them can approve it and run it. Nothing is written into the project, so there
is nothing to commit.

On the Mac or server that denied it:

- its triggers do not run it, and **Run now** does not either, until it is approved there;
- it stays in its place on the list, marked **Denied on this host**, not under
  **Archived workflows**;
- it no longer counts as waiting, so it frees a place among the three that may wait, and
  it does not count towards the approved workflows that may run;
- **Approve** is still there, and takes the denial back without bringing an archive back.

`hosts:` in the file is not the same thing: it is a list written into the shared file,
and taking a computer off it is a change you commit.

### Asked as a question

A workflow waiting for your OK is also asked as a question, the same one a change to
`.agents/project.json` or `.agents/pins.json` made outside the app is (#569): over the
prompt of the agent whose turn was running when the file changed, or on the project's
page when none was (a merge or pull, or something outside the app), and notified like
any question. It says who changed the file, the lines removed and added against the copy
you last approved, and offers **Keep** and **Undo**:

- **Keep** is **Approve**, of the file as you were shown it.
- **Undo** writes the copy you last approved back into the file, or removes the file
  when you never approved one. The app keeps that copy beside its approval, outside the
  project, from the moment it is approved. A workflow approved before copies were kept
  gets one the next time its file is seen as approved; until then Undo says it has
  nothing to put back, and **Keep** or **Deny on This Host** are the answers.

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
`standing` workflow keeps, what you have approved or denied, and who turned it off. That last is
why a workflow turned off on another clone says **Off: its file says enabled: false**
here.

They differ in what else they do:

| | Turned off | Archived |
| --- | --- | --- |
| Where it is listed | In its place, marked **Off** | Under **Archived workflows** |
| Its triggers | Do not run it; each one skipped is counted on its row | Do not run it; nothing is recorded |
| **Run now** | Runs it, to try it | Refuses |
| The [limits](#limits) | Frees its place among the ones that run; turning it on again is refused when they are all taken | Frees its place |
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
- [Start a workflow from an MCP event](../how-to/start-a-workflow-from-an-mcp-event.md)
- [Events](events.md)
- [Tools the app gives agents](agent-tools.md)
