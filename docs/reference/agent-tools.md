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
| `finish_turn` | Ends the agent's turn and says how it went: **Complete**, **Nothing to do**, **Waiting on your answer**, **Partly done**, **Stuck** or **Blocked**, with a one- or two-sentence message that shows under the agent's name. It can also name the conversation, and offer the one thing you are most likely to say next, which waits in your prompt. For **Blocked**, it names the agents it is waiting on, or how many minutes until it checks again, and the agent carries on by itself when the wait is over. A block that names neither needs you to carry it on. An unread ending appears under **Needs you** until opened. An agent that has finished and cleaned up can ask to be **parked** (with **Complete**, **Nothing to do** or **Partly done**) or **archived** (with **Complete** or **Nothing to do**) once the turn ends. The ask is dropped if you send it something first. On Claude, Copilot, Cursor and Codex — the runtimes that can carry the conversation into another folder — it can also move the agent once the turn ends: `worktree` names a new worktree of the project or gives the path of one that exists, and `leave_worktree` (`keep` or `remove`) goes back to the project folder. The agent is started again there to carry on, so a move doesn't go with **Waiting on your answer**, **Blocked** or a park. Nothing uncommitted comes along. Removing is refused for a worktree the app did not make or another agent works in, and, unless the agent says to discard, when anything in it is uncommitted or unmerged. | No. The app answers. |
| `show_file` | Opens a file in the files pane beside the conversation, at a line. A Markdown file opens as a page that follows the agent's edits. The file must be inside the folders the agent was given. If you are reading another conversation, it waits until you open this one. | No. The app answers. |
| `manage_workflows` | Lists, reads, writes and removes this project's workflows. A workflow an agent writes or changes appears on the project page straight away, waiting for your OK: it does not run until you click **Approve**, and you can archive it instead. See [Workflow triggers and actions](workflows.md). | No. The app answers. |
| `ask_form` | Asks you a question or a short form and waits for your answer. Reaches you on the Mac or on your phone. Used when the runtime has no working ask tool of its own, or when that tool never reaches the model. | No. The app answers. |
| `start_agent` | Starts another agent in this project with a prompt of its own, marked as started by this agent. It can choose the runtime, model, a permission mode no looser than its own, and whether to work in the project folder, a new worktree, an existing worktree or a branch. At most five agents started by agents can exist in a project at once, until one is archived. | The runtime decides. |
| `stop_agent` | Stops an agent this agent started, as your **Stop** would. | The runtime decides. |
| `park_agent` | Parks an agent this agent started, as your **Park** would. If it is still working, it finishes its turn first. It stays listed under **Parked** and keeps its place until you archive it. | The runtime decides. |
| `list_my_agents` | Lists the agents this agent started that are not archived, what each is doing and last said, and how many of the five places are in use. | The runtime decides. |
| `list_sessions` | Lists the sessions in this project, most recent first, its own included: each one's id, title, runtime, status and what it last said. Nothing from another project. | No. The app answers. |
| `read_session` | Reads one session in this project, by its id or exact title: what you asked, what the agent said, the tools it ran and the files they touched, what it said of how the work went, and its plan as it last stood. A long one keeps the first request and the latest turns and says how many were left out. Reading it changes nothing. A title used twice, a retired session, or one not in this project is refused in words. Used when you ask an agent to continue another session's work. | No. The app answers. |
| `lease_resource` | Takes a turn with something only one agent should use at a time: a simulator, a browser, the screen, or anything it names. Waits up to 45 seconds if someone else holds it, then keeps the agent's place in line. A lease lasts 30 minutes unless the agent asks for up to 240, and calling it again extends it. | The runtime decides. |
| `release_resource` | Gives back a lease, or leaves the line for one. | The runtime decides. |
| `list_resources` | Lists what can be leased on this Mac, and who holds or is waiting for what. | The runtime decides. |
| `wait_for_event` | Waits until something happens in this project or on this Mac, such as `agent.finished`, `branch.moved`, `mac.wake` or a `custom.` event, optionally narrowed by details and with a time limit of 1 minute to 24 hours. The call waits up to 45 s; after that the agent can end its turn, which costs nothing, and it is started again when the event happens or the time runs out. One wait per agent; a new one replaces the old. Also lists recent events and every name it can wait for. See [Events](events.md). | The runtime decides. |
| `cancel_wait` | Stops the agent's wait, so nothing starts it again for it. | The runtime decides. |
| `publish_event` | Says that something happened, as a `custom.` event such as `custom.build_green`, with a short message and up to 10 details. Agents waiting on it are started and workflows that trigger on it run, and the agent is told which. At most 30 an hour per agent. | The runtime decides. |
| `suggest_next_prompts` | The older name for the suggestion half of `finish_turn`, kept for conversations started before it. | No. The app answers. |
| `report_outcome` | The older name for the outcome half of `finish_turn`, kept for conversations started before it. | No. The app answers. |

`start_agent`, `stop_agent`, `park_agent` and `list_my_agents` are given only to an
agent that you or a workflow started. An agent started by another agent cannot start
agents of its own. Only you can archive an agent. `list_sessions` and `read_session` are
given to every agent, including one another agent started.

## See also

- [Have an agent wait for something](../how-to/wait-for-something.md)
- [Start an agent in its own worktree](../how-to/start-in-a-worktree.md)
- [Events](events.md)
- [Leases on shared resources](../explanation/leases.md)
- [Why agents' own tools are taken away](../explanation/scoped-tools.md)
- [Runtimes](runtimes.md)
- [Statuses and groups](statuses.md)
