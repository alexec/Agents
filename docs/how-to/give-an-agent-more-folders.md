---
diataxis: how-to
devices: [mac]
description: Let a new agent work in more than one folder, and give it connectors of its own.
---

# Give an agent more folders and connectors

An agent works in its folder, or its worktree, and nothing outside it. When the
work spans two repositories, or needs a tool only a connector (an MCP server) offers, you can give a new
agent more before it starts.

## Before you start

- A folder on this Mac. See [Add a folder](add-a-folder.md).
- For a connector, the command that starts it, as you would type it in Terminal.

## Steps

1. Unfold the folder in the sidebar and click **New session**, the first row under it (or press ⌘N).
2. Above the prompt, click **Reach: this folder** (**Folders and connectors this agent
   may reach**).

   A sheet opens, with **Folders** and **Connectors**. The folder is listed
   first and cannot be removed.
3. To add a folder, click **Add a folder** and pick it. Click **×** beside one to take it
   off again.
4. To add a connector, type a **Name** and the **Command, as you would type it**, then
   click **Add**.
5. Click **Done**.

   The capsule now says what the agent reaches, such as **Reach: 2 folders · 1 connector**.
6. Type the prompt and send it.

   The runtime is told about every folder listed, where it can take more than one, and
   what the app does for the agent reaches them too: reading and writing files for it,
   `show_file`, and the files `@` offers. Writes still go through the permission question.
   The connectors are started for this agent only.

The choice is made when the agent starts, and cannot be changed afterwards. To give every
agent the same connectors, put them in `~/.agents` instead; see
[Share skills, instructions and connectors with every agent](share-skills-across-agents.md).

## If it doesn't work

- **There is no Reach capsule.** It is shown only before the first prompt of a new
  session. Start a new one.
- **The agent says a tool from the connector is missing.** A connector that will not start is
  reported on the agent and does not stop it. Check the command in Terminal.
