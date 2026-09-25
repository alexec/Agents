---
diataxis: reference
devices: [mac, iphone, ipad, server]
description: Every tool the app gives an agent, what it does, and whether you are asked before it runs.
---

# Tools the app gives agents

The app gives every agent it starts a set of tools of its own, alongside the runtime's
tools. This page lists them all, in the order an agent sees them. Copilot conversations
get none of them (see [Runtimes](runtimes.md)).

The last column says whether you are asked before the tool runs. Where it says the app
answers, the runtime's permission question is answered by the app and you do not see it.
Where it says the runtime decides, you get the same permission card as for any other tool
if the runtime asks; Claude and Cursor ask.

| Tool | What it does | Asks the person first? |
| --- | --- | --- |
| `finish_turn` | Ends the agent's turn and says how it went: **Complete**, **Nothing to do**, **Waiting on your answer**, **Partly done**, **Stuck** or **Blocked**, with a one- or two-sentence message that shows under the agent's name. It can also name the conversation, and offer the one thing you are most likely to say next, which waits in your prompt. For **Blocked**, it names the agents it is waiting on, or how many minutes until it checks again, and the agent carries on by itself when the wait is over. | No. The app answers. |
| `show_file` | Opens a file in the files pane beside the conversation, at a line. A Markdown file opens as a page that follows the agent's edits. The file must be inside the folders the agent was given. If you are reading another conversation, it waits until you open this one. | No. The app answers. |
| `manage_workflows` | Lists, reads, writes and removes this project's workflows. A workflow an agent writes appears on the project page straight away, where you can archive it. See [Workflow triggers and actions](workflows.md). | No. The app answers. |
| `start_agent` | Starts another agent in this project with a prompt of its own, marked as started by this agent. It can choose the runtime, model, permission mode, and whether to work in the project folder, a new worktree, an existing worktree or a branch. At most three agents started by agents can exist in a project at once, until one is archived. | The runtime decides. |
| `stop_agent` | Stops an agent this agent started, as your **Stop** would. | The runtime decides. |
| `archive_agent` | Archives an agent this agent started, stopping it first, which frees its place. | The runtime decides. |
| `list_my_agents` | Lists the agents this agent started that are not archived, what each is doing and last said, and how many of the three places are in use. | The runtime decides. |
| `lease_resource` | Takes a turn with something only one agent should use at a time: a simulator, a browser, the screen, or anything it names. Waits up to 45 seconds if someone else holds it, then keeps the agent's place in line. A lease lasts 30 minutes unless the agent asks for up to 240, and calling it again extends it. | The runtime decides. |
| `release_resource` | Gives back a lease, or leaves the line for one. | The runtime decides. |
| `list_resources` | Lists what can be leased on this Mac, and who holds or is waiting for what. | The runtime decides. |
| `push_pull_request` | Pushes the agent's commits to the pull request its run was started for. Never force-pushes. Only works in a run a pull-request workflow started. | No. The app answers. |
| `reply_on_pull_request` | Replies on the pull request its run was started for, either in a review comment's thread or on the pull request itself. Only works in a run a pull-request workflow started. | No. The app answers. |
| `suggest_next_prompts` | The older name for the suggestion half of `finish_turn`, kept for conversations started before it. | No. The app answers. |
| `report_outcome` | The older name for the outcome half of `finish_turn`, kept for conversations started before it. | No. The app answers. |

`start_agent`, `stop_agent`, `archive_agent` and `list_my_agents` are given only to an
agent that you or a workflow started. An agent started by another agent cannot start
agents of its own.

## See also

- [How-to guides](../how-to/index.md)
- [Explanation](../explanation/index.md)
