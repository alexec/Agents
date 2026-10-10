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
| Command-N | **File ▸ New Session** | Starts a new session in the selected project, the same as the compose button above the sessions column. |
| Option-Command-N | **File ▸ New Session in a Worktree** | Starts a new session in the selected project, in a new worktree. |
| Shift-Command-N | **File ▸ New Chat** | Starts a chat in this Mac's **chat** project, with no project to pick. See [Chat without a project](../how-to/chat-without-a-project.md). |
| Command-O | **File ▸ Add Project…** | Adds a folder as a project. |
| Shift-Command-O | **File ▸ Clone Project from Git URL…** | Clones a Git URL as a project. |
| Control-Command-O | **File ▸ Add Server…** | Adds a Linux server. |
| Shift-Command-R | **File ▸ Show in Finder** | Shows the agent's or project's folder in Finder. |
| Option-Command-, | **File ▸ Project Settings…** | Opens the selected project's settings: its instructions, skills, plugins, MCP servers and worktrees. |
| Command-. | **Session ▸ Stop** | Stops the agent and stays on the conversation. |
| Shift-Command-Return | **Session ▸ Carry On** | Tells an agent blocked under **Needs you** that its block has gone, or a **Waiting** one that its wait is over early. |
| Option-Command-Delete | **Session ▸ Archive** or **Bring Back** | Archives the session, or brings an archived one back. |
| Delete | Selected session(s) in the sessions list | Archives the highlighted session, or every highlighted one that is not already archived (⌘-click to pick several). |
| Option-Command-B | **Session ▸ Branch** | Starts a new agent from this conversation so far. |
| Option-Command-Down Arrow, Option-Command-Up Arrow | **Go ▸ Next Session**, **Previous Session** | Moves through the sessions in the list. |
| Command-J | **Go ▸ Next Needing Attention** | Opens the next session under **Needs you**, then the next unread finished session. |
| Control-Command-1 to 9 | **Go ▸** a project | Opens that project. |
| Option-Command-I | **View ▸ Show Inspector** or **Hide Inspector** | Opens or closes the sidebar beside the conversation. |
| Command-1 to Command-6 | **View ▸ Files**, **Changes**, **Terminal**, **Browser**, **Exchanged**, **Background** | Opens that pane of the sidebar. While a permission or question card is up, these yield to the card's answers. |
| Control-` | **View ▸ Project Terminal** | Shows or hides the selected project's own shells, one to a tab, in its folder under the page, with or without an agent chosen. Hiding them leaves them running. |
| Command-Down Arrow | **View ▸ Jump to Latest** | Scrolls the conversation to its end. |
| Option-Command-E | **View ▸ Events** | Opens the Events page. |
| Option-Command-L | **View ▸ Resources** | Opens the Resources page, which shows who holds or is waiting for the simulators, browsers and screen. |
| Option-Command-R | **View ▸ Runtimes** | Opens the Runtimes page, which shows what each runtime can be started on right now and where its allowance stands. |
| Option-Command-S | **View ▸ Spending** | Opens the Spending page. See [Limit what agents spend](../how-to/limit-spending.md). |
| Command-F | **View ▸ Find Session** | Puts the keyboard in the sessions column's search field. |
| Command-P | **Go ▸ Open File…** | Finds a file in the open session's folders by name, to read or edit. |
| Command-? | **Help ▸ Agents Help** | Opens these docs. |
| Command-, | **Agents ▸ Settings…** | Opens [Settings and the Resources page](settings.md). |
| Return, Escape | In a sheet or dialog | Takes the highlighted button, or cancels. |
| Return | On a permission or question card | Takes the first allowing answer, or **Submit** on a multi-step form. |
| Command-1 to Command-9 | On a permission or question card | Picks that option by position. |
| Command-. | In a shell | Interrupts what is running, as Control-C does, instead of stopping the agent. |
| Command-K | In a shell | Clears the screen and what scrolled off it. |
| Command-F | In a shell | Finds in the shell's text, instead of finding a session. |
| Command-T, Command-W | In a shell | Opens another shell, or closes this one. |

While a shell has the keyboard, every other shortcut on this page still works, with no
need to click out of it first. See [Use a shell in an agent's folder](../how-to/use-a-shell.md#keys-in-a-shell).

## See also

- [Read an agent's changes](../how-to/read-an-agents-changes.md)
- [Use a shell in an agent's folder](../how-to/use-a-shell.md)
- [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)
- [Settings, and the Runtimes and Resources pages](settings.md)
- [Statuses and groups](statuses.md)
