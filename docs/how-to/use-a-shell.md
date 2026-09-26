---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Open shells in an agent's folder from the Terminal pane, one per tab, and keep them running.
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

## If it doesn't work

- **The shell is no longer running.** It exited, for example after `exit`. Click **New
  shell** to open another.
- **+ is greyed out.** On a server with an older version of Agents, which holds one shell
  per agent. The server updates when nothing is mid-turn there.
