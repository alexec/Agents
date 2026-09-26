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
| `on:` `pull-request-checks-failed` | No settings | Runs when checks fail on one of your open pull requests in this project's GitHub repository. |
| `on:` `pull-request-review-comments` | No settings | Runs when one of your open pull requests gets review comments from someone with write access to the repository. |
| `on:` `pull-request-conflicts` | No settings | Runs when one of your open pull requests conflicts with its base branch. |
| `on:` an event name, such as `pull_request.merged` or `custom.build_green` | Optionally the event's details, as filters | Runs when that event happens. Any name on [Events](events.md) works, or a subject with `.*`, such as `pull_request.*`, for all of its events. Under the name, list details to narrow it, such as `number: 41`; a detail the event does not carry is an error in the file. An event about this Mac runs matching workflows in every project. A name this version does not know is shown on the workflow's page and never runs. |
| `agent:` `new` | The default | Each run starts a new agent. |
| `agent:` `standing` | | Each run goes to the workflow's own agent, which keeps its conversation from run to run. |
| `agent:` `triggering` | | Each run goes to the agent that set it off. For a pull-request trigger, that is the agent last active in the pull request's worktree. For an event, it is the agent the event is about, or the agent that published a `custom.` event. A schedule, or an event with no agent, has no such agent, so it does not run. |
| `permission-mode:` | One of the runtime's own modes, such as a read-only or plan mode | The mode the agent runs in. A workflow runs with nobody watching, so this is how to say it must not change anything. |
| `runtime:` | `claude`, `grok`, `copilot`, `cursor` | The runtime the agent runs on. Without it, Claude. |
| `model:` | One of the runtime's models | The model the agent uses. Without it, the runtime's own default. |
| `effort:` | One of the runtime's levels, such as `low` or `high` | How hard the agent thinks. Without it, the runtime's own default. |
| `options:` | Any other option the runtime offers, by its id, such as `fast: true` | Sets that option for the agent. |

For example, to start a new agent whenever pull request 41 is merged, or another agent
publishes `custom.build_green`:

```markdown
---
name: After the build
on:
  - pull_request.merged:
      number: 41
  - custom.build_green
agent: new
---

Deploy the docs, then say what you deployed.
```

The older hyphenated names still work, and each answers to the events listed under
[Older trigger names](events.md#older-trigger-names). On a workflow's page, its latest run
shows the event that caused it, with a link to it on the Events page.

A setting the runtime does not offer stops the workflow running, rather than falling back
to a default. The workflow's page shows which values the runtime offers once it has been
used in this project.

A workflow does not run, and its page says why, when:

- a run of it is still going;
- it is archived;
- it is not one of the first three workflows in its project that are not archived, taken
  in order of file name, or not one of the first ten of those across every project.
  Archiving one makes room;
- it was set off by a chain of workflows already three deep;
- the day's spending limit has been reached;
- the project folder is not there;
- its `agent:` is `triggering` and the agent it would have resumed is gone, or nothing
  set it off;
- for a pull request: it has no local worktree, its worktree has uncommitted changes, an
  agent is already working there, or it has already run three times in a row for that
  pull request;
- the file cannot be read, or names a trigger or `agent:` value this version does not
  know. The page says what is wrong with the file.

Pull requests are checked every five minutes.

On the Mac, each workflow on the project page has **Open**, **Run now**, **Archive**
(**Restore** once archived) and **Show in Finder**.

## See also

- [How-to guides](../how-to/index.md)
- [Explanation](../explanation/index.md)
