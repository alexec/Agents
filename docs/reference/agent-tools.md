---
diataxis: reference
devices: [mac, iphone, ipad, server]
description: Every tool the app gives an agent, what it does, and whether you are asked before it runs.
---

# Tools the app gives agents

The app gives every agent it starts a set of tools of its own, alongside the runtime's
tools, on every runtime (see [Runtimes](runtimes.md)). This page lists them all, in the
order an agent sees them. Copilot takes them over a local http address the app serves
only to that agent, and uses its own follow-up suggestions instead of the app's.

The last column says whether you are asked before the tool runs. Where it says the app
answers, the runtime's permission question is answered by the app and you do not see it.
Where it says the runtime decides, you get the same permission card as for any other tool
if the runtime asks; Claude and Cursor ask, and Copilot asks before every tool call.

| Tool | What it does | Asks the person first? |
| --- | --- | --- |
| `finish_turn` | Ends the agent's turn and says how it went: **Complete**, **Nothing to do**, **Waiting on your answer**, **Partly done**, **Stuck** or **Blocked**, with a one- or two-sentence message that shows under the agent's name. It can also name the conversation, and offer the one thing you are most likely to say next, which waits in your prompt. For **Blocked**, it names the agents it is waiting on, or how many minutes until it checks again, and the agent carries on by itself when the wait is over. A block that names neither needs you to carry it on. An agent that has finished and cleaned up can ask to be **parked** (with **Complete**, **Nothing to do** or **Partly done**) once the turn ends. It can't archive itself: you can, and so can the agent that started it. The ask is dropped if you send it something first. On Claude, Copilot, Cursor and Codex — the runtimes that can carry the conversation into another folder — it can also move the agent once the turn ends: `worktree` names a new worktree of the project or gives the path of one that exists, and `leave_worktree` (`keep` or `remove`) goes back to the project folder. The agent is started again there to carry on, so a move doesn't go with **Waiting on your answer**, **Blocked** or a park. Nothing uncommitted comes along. Removing is refused for a worktree the app did not make or another agent works in, and, unless the agent says to discard, when anything in it is uncommitted or unmerged. | No. The app answers. |
| `show_file` | Opens a file in the files pane beside the conversation, at a line. A Markdown file opens as a page that follows the agent's edits; an HTML file opens rendered, with scripts and the network off (see [Look at an HTML page](../how-to/look-at-an-html-page.md)). The file must be inside the folders the agent was given. If you are reading another conversation, it waits until you open this one. | No. The app answers. |
| `manage_workflows` | Lists, reads, writes and removes this project's workflows, and turns them off and on. A workflow an agent writes or changes appears on the project page straight away, waiting for your OK: it does not run until you click **Approve**, and you can archive it instead. A new one an agent writes also starts turned off, and its page says **Off: written by an agent** until you turn it on. An agent can turn any workflow off, but can turn back on only one an agent turned off: one you turned off, one an agent wrote, and one whose file says `enabled: false` for any other reason stay off until you turn them on. Off and archived are lines in the workflow's own file (`enabled: false`, `archived: true`), so turning one off writes that file; an agent's rewrite of a workflow keeps whatever those lines said. A project may have at most three workflows waiting for your OK; an agent writing a fourth is refused until you approve or remove one. Approved ones don't count. See [Workflow triggers and actions](workflows.md) and its [limits](workflows.md#limits). | No. The app answers. |
| `ask_form` | Asks you a question or a short form and waits for your answer. Reaches you on the Mac or on your phone. Used when the runtime has no working ask tool of its own, or when that tool never reaches the model. | No. The app answers. |
| `start_agent` | Starts another agent in this project with a prompt of its own, marked as started by this agent. It can choose the runtime, model, a permission mode no looser than its own, and whether to work in the project folder, a new worktree, an existing worktree or a branch. It is refused if the project would go over either of its two helper limits, how many may be running and how many may exist not yet archived (3 and 5 unless you set them in **Project Settings ▸ General**), and the refusal says which and names the agents holding it. A runtime that can't take an agent on this Mac (not installed, not signed in, or out of the pool on the **Agent Runtimes** page) is refused before anything starts, with the reason and the runtimes that can; so is a model the runtime doesn't offer, naming the ones it does. With no runtime named, it starts on Claude, which is checked the same way. | The runtime decides. |
| `stop_agent` | Stops an agent this agent started, as your **Stop** would. That frees its running place; it keeps its not-archived place until you archive it. | The runtime decides. |
| `park_agent` | Parks an agent this agent started, as your **Park** would. If it is still working, it finishes its turn first. It stays listed under **Parked**. Parking frees its running place; it keeps its not-archived place until it is archived. | The runtime decides. |
| `archive_agent` | Archives an agent this agent started, as your **Archive** would, once its work is merged or abandoned. That frees its not-archived place. Its conversation says which agent archived it, `agent.archived` says `by` another agent, and you can bring it back from **Archived**. Refused, in words, for the agent itself, your own sessions, another agent's helpers, a helper that is still working (it says to wait or to stop it first with `stop_agent`), and every agent when **Agents may archive the helpers they started** is off in **Project Settings ▸ General** (on unless you turn it off). | The runtime decides. |
| `list_my_agents` | Lists the agents this agent started that are not archived, what each is doing and last said, and how many of the project's running and not-archived places are in use, such as "2 of 3 running, 4 of 5 not archived". It ends with the runtimes `start_agent` can start one on here, as of that moment, each with its model where this project has used it, and why each of the others can't. | The runtime decides. |
| `list_sessions` | Lists the sessions in this project, most recent first, its own included: each one's id, title, runtime, status and what it last said. Nothing from another project. | No. The app answers. |
| `read_session` | Reads one session in this project, by its id or exact title: what you asked, what the agent said, the tools it ran and the files they touched, what it said of how the work went, and its plan as it last stood. A long one keeps the first request and the latest turns and says how many were left out. Reading it changes nothing. A title used twice, a retired session, or one not in this project is refused in words. Used when you ask an agent to continue another session's work. | No. The app answers. |
| `lease_resource` | Takes a turn with something only one agent should use at a time: a simulator, a browser, the screen, or anything it names. Waits up to 45 seconds if someone else holds it, then keeps the agent's place in line. A lease lasts 30 minutes unless the agent asks for up to 240 (or the declared resource's own lengths), and calling it again extends it. A declared resource may allow more than one holder at once. | The runtime decides. |
| `release_resource` | Gives back a lease, or leaves the line for one. | The runtime decides. |
| `list_resources` | Lists what can be leased on this Mac, and who holds or is waiting for what. Resources declared in Settings ▸ Resources come first, with their descriptions, even when free; the agent is told to lease one whenever its description applies. | The runtime decides. |
| `wait_for_event` | Waits until something happens in this project or on this Mac, such as `agent.finished`, `branch.moved`, `mac.wake` or a `custom.` event, optionally narrowed by details (one value each, or a list meaning any of them, such as `{"outcome": ["done", "nothing_to_do"]}`; a value a detail cannot have is refused, naming the ones it can) and with a time limit of 1 minute to 24 hours. The call waits up to 45 s; after that the agent can end its turn, which costs nothing, and it is started again when the event happens or the time runs out. One wait per agent; a new one replaces the old. Also lists recent events and every name it can wait for. See [Events](events.md). | The runtime decides. |
| `cancel_wait` | Stops the agent's wait, so nothing starts it again for it. | The runtime decides. |
| `publish_event` | Says that something happened, as a `custom.` event such as `custom.build_green`, with a short message and up to 10 details. Agents waiting on it are started and workflows that trigger on it run, and the agent is told which. At most 30 an hour per agent. | The runtime decides. |
| `set_tile` | Creates or replaces a tile on the project's Dashboard: a number with its trend, a status light, a table, a note or a link, with a title, an optional section and where its value came from. The agent keeps the tiles it sets (an agent a workflow started keeps them for the workflow), and another agent's tile is refused with its keeper named, unless that keeper is archived or retired, or is a session this agent has read with `read_session`, and the agent asks to take it over. The app writes the tile whole to `.agents/dashboard/<id>.json` in the project folder, never in a worktree, and never commits it; a number's trend goes beside it in `.agents/dashboard/history/<id>.jsonl`. Setting the same value again only refreshes its age. The answer says when you have hidden the tile, or removed it (it comes back, with who removed it and when). At most 120 an hour per agent and 60 tiles a project. See [Dashboard tiles](dashboard-tiles.md). | No. The app answers. |
| `remove_tile` | Removes a tile this agent keeps from the Dashboard, with its history. | No. The app answers. |
| `read_dashboard` | Lists every tile on the project's Dashboard, hidden ones included: its value, who keeps it, how old it is, whether it is greyed, hidden or changed outside the app, and a number's last 10 values. | No. The app answers. |

`finish_turn` can also add or remove labels owned by the agent. `start_agent` can give
the helper up to five labels, which the helper owns from its first moment. Labels are
unique within a session without regard to case. An agent cannot remove or claim a
person-owned label; the whole `finish_turn` call is refused if it tries. See
[Label a session](../how-to/label-a-session.md).

`start_agent`, `stop_agent`, `park_agent`, `archive_agent` and `list_my_agents` are given
only to an agent that you or a workflow started. An agent started by another agent cannot
start agents of its own. An agent can archive only the agents it started, never itself and
never your sessions.

A helper counts as **running** while it is working, waiting on a question or permission,
starting, or waiting to carry on by itself: blocked on other agents or a time, waiting on
events, or waiting for an allowance. Finished, stopped, parked and archived helpers don't.
So a lead that stops or parks a helper whose part is done frees a running place at once; the
helper's not-archived place stays taken until it is archived. A lead should archive a
helper once its work is merged or abandoned, rather than remove the helper's worktree under
it; archiving removes a worktree the app made for it once everything in it is committed. Both limits are yours alone to
change: the tools only read them. They are kept in the project's `.agents/project.json`;
a value written there by hand is held to the maximums. `list_sessions` and `read_session` are
given to every agent, including one another agent started.

## See also

- [Have an agent wait for something](../how-to/wait-for-something.md)
- [Start an agent in its own worktree](../how-to/start-in-a-worktree.md)
- [Events](events.md)
- [Leases on shared resources](../explanation/leases.md)
- [Why agents' own tools are taken away](../explanation/scoped-tools.md)
- [Runtimes](runtimes.md)
- [Statuses and groups](statuses.md)
