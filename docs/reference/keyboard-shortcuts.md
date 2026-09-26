---
diataxis: reference
devices: [mac]
description: Every keyboard shortcut and menu command Agents adds on the Mac.
---

# Keyboard shortcuts

This page lists every keyboard shortcut and menu command Agents has on the Mac, beyond the
ones every Mac app has.

| Keys | Where | What it does |
| --- | --- | --- |
| Return | In the prompt | Sends the prompt. If the agent is still working, the prompt waits and goes when the turn ends; on some runtimes **Send now** puts it into the running turn. See [Send a prompt while an agent is working](../how-to/send-while-an-agent-works.md). |
| Option-Return | In the prompt | Starts a new line. |
| Command-Return | In the prompt | Sends the prompt, the same as the send button. |
| Tab | In the prompt, with a suggestion showing | Takes the suggested prompt into the prompt, for you to send or change. |
| Escape | In the prompt, with a suggestion showing | Puts the suggestion away until the next turn ends. |
| `/` | In the prompt, at the start of a word | Lists the runtime's commands that match what you type. |
| `@` | In the prompt | Lists the project's files that match what you type, to attach one. |
| Up Arrow, Down Arrow | In the prompt, with a list of commands or files showing | Moves through the list. |
| Return or Tab | In the prompt, with a list of commands or files showing | Takes the chosen command or file. |
| Escape | In the prompt, with a list of commands or files showing | Closes the list. |
| Command-N | **File ▸ New Session** | Starts a new session in the selected project, the same as **New session** at the top of the sessions column. |
| Option-Command-N | **File ▸ New Session in a Worktree** | Starts a new session in the selected project, in a new worktree. |
| Command-O | **File ▸ Add Project Folder…** | Adds a folder as a project. |
| Shift-Command-O | **File ▸ Clone Repository…** | Clones a Git URL as a project. |
| None | **File ▸ Add Server…** | Adds a Linux server. |
| Shift-Command-R | **File ▸ Show in Finder** | Shows the agent's or project's folder in Finder. |
| Command-. | **Session ▸ Stop** | Stops the agent and stays on the conversation. |
| Shift-Command-Return | **Session ▸ Carry On** | Tells a blocked agent its wait is over. |
| Control-Command-P | **Session ▸ Park** or **Unpark** | Puts the chat down to come back to later, or puts it back where it was. |
| Option-Command-Delete | **Session ▸ Archive** or **Bring Back** | Archives the agent, or brings an archived one back. |
| Option-Command-B | **Session ▸ Branch** | Starts a new agent from this conversation so far. |
| Option-Command-Down Arrow, Option-Command-Up Arrow | **Go ▸ Next Session**, **Previous Session** | Moves through the sessions in the list. |
| Command-J | **Go ▸ Next Needing Attention** | Opens the next agent that needs you. |
| Control-Command-1 to 9 | **Go ▸** a project | Opens that project. |
| Option-Command-I | **View ▸ Show Inspector** or **Hide Inspector** | Opens or closes the sidebar beside the conversation. |
| Command-1 to Command-6 | **View ▸ Files**, **Changes**, **Terminal**, **Browser**, **Exchanged**, **Background** | Opens that pane of the sidebar. |
| Command-Down Arrow | **View ▸ Jump to Latest** | Scrolls the conversation to its end. |
| Option-Command-E | **View ▸ Events** | Opens the Events page. |
| Option-Command-L | **View ▸ Resources** | Opens the Resources page, which shows who holds or is waiting for the simulators, browsers and screen. |
| Option-Command-S | **View ▸ Spending** | Opens the Spending page. |
| None | **View ▸ Pool** | Opens the Pool page. See [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md). |
| Command-? | **Help ▸ Agents Help** | Opens these docs. |
| Command-, | **Agents ▸ Settings…** | Opens [Settings](settings.md). |
| Return, Escape | In a sheet or dialog | Takes the highlighted button, or cancels. |

## See also

- [How-to guides](../how-to/index.md)
- [Explanation](../explanation/index.md)
