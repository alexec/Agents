---
diataxis: explanation
description: What a project is, why each one lives on a single machine, and why an agent can have a worktree of its own.
devices: [mac, server]
---

# Projects, hosts and worktrees

Every agent works in a project, every project lives on a host, and inside a project an
agent can have a worktree of its own. This page explains what each of those is and why the
app draws the lines where it does.

## A project is a folder

A project is one folder you work in, named after that folder. The app does not copy it,
import it or keep a second version of it: the agents work on the files in that folder, and
what they change is there when you look with any other tool. The app keeps only what the
folder cannot tell it, such as whether you have archived the project.

A project's agents are listed beside it on its page, grouped by what needs you, what is
working and what is done.

An agent is filed under one project, but it need not stay inside that one folder. Work
that spans two repositories is ordinary, so a new agent can be given more folders to reach,
and MCP servers of its own, before it starts. It is still listed under the project it
started in. See [Give an agent more folders and MCP servers](../how-to/give-an-agent-more-folders.md).

## A project lives on one host

A host is a machine where agents can do their work. Your Mac is one. A Linux server you
reach with SSH can be another, once you add it to the app.

Each project belongs to exactly one host, and its folder is a path on that host. An agent
in a project on a server runs on the server: its commands run there, its edits land
there, and the runtimes you can pick from are the ones installed and signed in on that
server, not on your Mac. The files pane, the terminal and the worktrees all show the
server's copy.

Projects on your Mac and projects on servers sit in the same list, and a server project
says which server it is on. There is no switch that turns the whole window into a view of
one server.

The reason for one host per project is that a folder is only ever in one place. Keeping
two copies of it on two machines in step would mean deciding, every time they differ,
which one is right, and an agent's half-finished edit is exactly the kind of difference
nobody can decide about. So the work happens where the folder is, and the window goes to
it.

## Why put a project on a server

The window only ever asks the daemon for things, so the daemon can be somewhere else. On
a server, the app puts its own daemon in your home folder there and reaches it through
your SSH connection. Nothing it runs on the server listens on a network port.

That buys three things. The agents on a server keep working while your Mac sleeps, loses
its network, or has the app closed, because nothing they need is on the Mac. The work can
happen on Linux, or on a machine with more room than a laptop. And the Mac stays quiet
while four agents build at once somewhere else.

When the Mac is away from a server, its projects show what the app last knew, marked as
not current, and the app does not take a prompt or an answer for them that it cannot
deliver. When the connection comes back, you see everything that happened meanwhile. On
the server, the daemon does not stop when it is idle, so it is still there for the next
connection.

For now, your iPhone and iPad see only the projects on your Mac.

## Why worktrees

Every agent in a project works in the project's folder unless you say otherwise. Two
agents changing code at once are then changing the same files: one's half-finished edit
breaks the other's build, a test run picks up both sets of changes, and nobody can say
afterwards which change came from which agent.

A git worktree is a second checkout of the same repository, in its own folder, on its own
branch, sharing one history. Changes made in one stay out of the others until someone
merges them. So when a project is a git repository, you can start an agent in a new
worktree, or send it into one that already exists, for instance to review what another
agent did there.

Each runtime has a worktree option of its own, but none of them could be relied on when
the app starts them. What every runtime does honour is the folder the app starts it in. So
the app makes the worktree itself and starts the agent there. The behaviour is the same
whichever runtime you pick.

A new worktree is named from the first few words of the prompt that starts it, and its
branch has the same name under `agents/`. It starts from the commit your project folder
has checked out, and it lives inside the repository, under `.agents/worktrees`. An agent
in a worktree is still listed in the same project, with the worktree's name on its row.
An agent that starts helpers of its own can put each one in a worktree too.

## An agent can change where it works

Where an agent works is not fixed when it starts. An agent that finds its task has grown
into something that needs its own branch can move into a worktree, or you can move it, and
it can move back to the project folder later. The app makes the move between turns, because
changing a runtime's folder while it is working is not something any runtime offers. The
app already starts the runtime afresh for each turn, so the next turn simply starts in the
new folder and picks up the same conversation.

Everything that follows an agent's folder follows the move: its files and changes, a
restart or resume, and archiving, which cleans up the worktree it moved into just as if it
had started there. A shell you had open stays where it is, since it is yours.

A runtime has to be able to pick its conversation back up in another folder for this to
work. Claude, Copilot, Cursor and Codex can. Grok cannot, and Gemini and Antigravity have not
been checked, so their agents are never moved: they would carry on having forgotten
everything.

## Worktrees are never removed by accident

Archiving an agent never throws work away. When you archive the last agent in a worktree
the app made, the worktree's folder goes only if everything in it is committed, and its
branch goes only if it has been merged. Otherwise both are left exactly as they are.

You can also remove a worktree yourself. The app refuses while an agent is working in it,
and tells you what would be lost, and asks you to confirm, if it has changes that are not
committed or a branch that is not merged.

## Your own set, and a project's

A project can carry its own `.agents` folder, with skills, instructions and plugins that
belong to that project and apply only inside it. `~/.agents` in your home folder is the same
idea one level up: your own set, which every agent the app starts gets, in every project and
on every runtime. The app lays it out on your Mac only; a project on a server gets the
project's own folder, and the runtimes on the server keep whatever they were set up with
there.

Your set goes to each runtime the way that runtime can take it, which differs. Some read
`~/.agents/skills` themselves; for others the app places links, which it never puts back
once you delete them; MCP servers go with each conversation as it starts, so nothing is
written into a runtime's own config. **Settings ▸ Shared** shows what each runtime ends up
with. See [Share skills, instructions and servers with every agent](../how-to/share-skills-across-agents.md).

A project's own skills are listed on its page, in a **Skills** section, where you can also
add one from skills.sh. Because the project's `.agents` folder is committed, a skill added
there reaches everyone who clones the project; one added in **Settings ▸ Shared** is yours
alone. A worktree has its own `.agents`, so a skill added on a worktree's page stays on that
branch until it is merged. Projects on a server don't show the section yet. See
[Add a skill from a catalogue](../how-to/add-a-skill-from-a-catalogue.md).

Nothing from a catalogue is taken on trust. skills.sh does not review what it lists, so the
app shows every file before anything is written, points out scripts an agent could run, pins
the commit it took, and checks each file against GitHub's own record of it at that commit.

## Related

- [How-to guides](../how-to/index.md), for adding a project, adding a Linux server and
  starting an agent in its own worktree.
- [Reference](../reference/index.md), for the settings that go with servers and projects.
