---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Start a chat without choosing a project, keep a file for a later chat, and chat on a server.
---

# Chat without a project

Not everything is a coding job in a repository. To ask an agent something, or have it write
a file or two, choose **New Chat**: there is no folder to pick and no project to add first.

A chat is an ordinary session of the **chat** project, which each host makes for you at
`~/.agents/chat` the first time it starts. Every chat on that host works in that one folder,
so a file one chat saves there is there for the next.

## Before you start

- At least one runtime installed on the host. See [Runtimes](../reference/runtimes.md).

## Steps

**Start a chat**

1. Choose **New Chat**:
   - **Mac:** **File ▸ New Chat** (Shift-Command-N), or **New Chat** at the top of the
     **+** menu over the projects list.
   - **iPhone or iPad:** **New Chat** (the pencil) at the top of the sidebar.
   - **Browser:** **New Chat** at the top of the **+** menu over the projects column.

   The **chat** project's page opens with the prompt ready, as **New Session** does for any
   project. There is no worktree choice: the folder is not a Git repository.
2. Type what you want and send.

The chat is listed under **chat** in the sidebar, like any project's sessions, and can be
parked, archived, labelled and searched the same way.

**Keep a file for a later chat**

Ask the agent to save it, for example "save this packing list so I can find it next time".
It writes into `~/.agents/chat`. A later chat, in the same folder, can read and change it,
even after the first chat has been archived and retired. The project's `AGENTS.md` says so to
every chat; it is yours to change.

Nothing in the folder is deleted by the app. Retiring a chat removes its conversation, not
the files it saved.

**Chat on a server**

If you have added a server, choose where the chat runs:

- **Mac:** **File ▸ New Chat On ▸** the server, or **New Chat** under the server's name in
  the **+** menu.
- **iPhone, iPad and browser:** the **New Chat** menu names each host.

Each host has its own `~/.agents/chat`, listed as `server:chat`. Files are not copied
between hosts.

## If it doesn't work

**No chat project** opens instead of a chat, with the reason:

- **The chat project on this Mac is archived.** You archived it. Choose **Unarchive** to
  bring it back and start the chat. While it is archived, the app leaves it archived.
- **This Mac has no personal home folder.** The copy of Agents you are running was started on
  a scratch root, which never touches your real home. Set `AGENTS_PERSONAL_HOME` for that
  copy to give it one.
- **… is a file, so there is no chat project.** Something that is not a folder is at
  `~/.agents/chat`. Move it away; the host makes the folder when it next starts.
- **… has no chat project.** The host is older than this feature, or not answering.

If you delete `~/.agents/chat`, the host makes it again, empty, when it next starts.

## See also

- [Add a project](add-a-project.md)
- [Projects, hosts and worktrees](../explanation/projects-hosts-worktrees.md)
- [Use Agents in a browser](use-agents-in-a-browser.md)
- [Keyboard shortcuts](../reference/keyboard-shortcuts.md)
