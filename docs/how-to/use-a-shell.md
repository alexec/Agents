---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Open shells in an agent's folder from the Terminal pane, or in the project folder with Control-`, one per tab, and keep them running.
---

# Use a shell in an agent's folder

Each agent has shells of its own, in the folder it works in, in the **Terminal** pane
beside the conversation. Use one to run the tests yourself, look at `git diff`, or start
a server while the agent works. On the Mac you can have several, one to a tab.

## Before you start

- An agent. Its shells open in its folder or worktree, on the Mac or on the server it
  runs on.

## Steps

1. Open the agent's conversation, and open the sidebar with the button at the top right
   of the window (**View ▸ Show Inspector**, Option-Command-I).
2. Click **Terminal** at the top of the sidebar, or press Command-3.

   The first shell, **Shell 1**, is already open in the agent's folder.
3. To open another, click **+** (**New shell**) at the end of the tabs. It opens in a new
   tab, **Shell 2**, and takes the keyboard. Click a tab to bring it forward.
4. To close one, click the **×** on its tab (**Close this shell**). The last tab has none.

Closing a tab is the only thing that ends a shell. Changing pane, opening another agent,
closing the window or quitting the app leaves every shell running, and the tabs are back
when you return.

If the agent has moved to a worktree since the shell opened, the pane says **This shell
is in** the old folder, and **Type cd there** types the `cd` to the new one for you.

**On iPhone and iPad**

Open **Terminal** from the conversation. It shows the agent's first shell, **Shell 1**,
and has no tabs.

## A shell in the project folder

Press Control-` (**View ▸ Project Terminal**) to open a shell in the selected project's
own folder, on the project's Mac or server, under whatever page is open. It needs no
agent: it opens with none chosen, and choosing an agent in the project leaves it where it
is, in the project folder, not the agent's worktree. Another project shows that project's
shells.

Click **+** (**New shell**) for another, in a tab of its own, as in an agent's pane.
Press Control-` again, or click the down arrow, to hide them; they keep running. Click a
tab's **×** to end that shell; closing the last puts the panel away. Drag its top edge
to make it taller.

On iPhone and iPad, choose **Project Terminal** from a project page's **…** menu, or
press Control-` on an iPad keyboard. It has the same tabs as the Mac. **Done** puts it
away; **End Shell** ends the shell in front.

## Keys in a shell

While a shell has the keyboard on the Mac, five keys are the terminal's, as in Terminal:

- Command-. interrupts what is running, as Control-C does.
- Command-K clears the screen and what scrolled off it.
- Command-F finds in the shell's text.
- Command-T opens another shell, and Command-W closes this one.

Every other shortcut works as it does anywhere else in the window: Command-N, Control-`,
Control-Command-S and the rest of [Keyboard shortcuts](../reference/keyboard-shortcuts.md).
You don't have to click out of the shell first. To stop the agent or find a session
instead, click out of the shell, or use the menu.

## If it doesn't work

- **The project shell says There is no such agent.** The project is on a server with an
  older version of Agents. The server updates when nothing is mid-turn there.
- **The shell is no longer running.** It exited, for example after `exit`. Click **New
  shell** to open another.
- **+ is greyed out.** On a server with an older version of Agents, which holds one shell
  per agent. The server updates when nothing is mid-turn there.
