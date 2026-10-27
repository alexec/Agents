---
diataxis: explanation
description: What a folder is, why each one lives on a single machine, and why an agent can have a worktree of its own.
devices: [mac, server]
---

# Folders, machines and worktrees

Every agent works in a folder, every folder lives on a machine, and inside a folder an
agent can have a worktree of its own. This page explains what each of those is and why the
app draws the lines where it does.

## A folder is a directory on one machine

A folder is one folder you work in, named after that folder. The app does not copy it,
import it or keep a second version of it: the agents work on the files in that folder, and
what they change is there when you look with any other tool. The app keeps only what the
folder cannot tell it, such as whether you have archived the folder.

A folder's agents are listed beside it on its page, grouped by what needs you, what is
working and what is done.

An agent is filed under one folder, but it need not stay inside that one folder. Work
that spans two repositories is ordinary, so a new agent can be given more folders to reach,
and connectors of its own, before it starts. It is still listed under the folder it
started in. See [Give an agent more folders and connectors](../how-to/give-an-agent-more-folders.md).

A folder need not be a Git repository. Worktrees, branches and the git half of an
agent's changes need one, and are simply not offered in a folder that is not; everything
else works the same.

No folder is made for you (#2134). To ask an agent something that needs no repository,
add any folder as a folder, such as an empty one, and start a session in it. A machine that
still has the **chat** folder at `~/.agents/chat` from an earlier version keeps it as an
ordinary folder: archive it, or keep using it, as any other.

## A folder lives on one machine

A machine is a machine where agents can do their work. Your Mac is one, once Agents Host runs
on it. A Linux server can be another, and so can a second Mac, once it joins your control
plane (see [The control plane](control-plane.md)).

Each folder belongs to exactly one machine, and its folder is a path on that machine. An agent
in a folder on a server runs on the server: its commands run there, its edits land
there, and the runtimes you can pick from are the ones installed and signed in on that
server, not on your Mac. The files pane, the terminal and the worktrees all show the
server's copy. The same is true of a folder on this Mac: the window asks this Mac's machine
for its files just as it asks a server's.

Folders on every machine sit in the same list, each under its machine's heading, in every
window and on every phone and iPad. There is no switch that turns the whole window into a
view of one machine.

The reason for one machine per folder is that a folder is only ever in one place. Keeping
two copies of it on two machines in step would mean deciding, every time they differ,
which one is right, and an agent's half-finished edit is exactly the kind of difference
nobody can decide about. So the work happens where the folder is, and the window goes to
it.

## Machines join by connecting out

A machine is never reached by anything. It connects out to your control plane over HTTPS,
with a key of its own, and keeps that connection open. To add a machine, you run one
command on it, which a window shows you with a code that works once; it installs the machine
there in your home folder, and the machine joins. A window can instead install it for you over
ssh with a key you give for that install only; afterwards the control plane keeps neither
the key nor the session, and the server connects out like any other. See
[Add a machine](../how-to/add-a-machine.md).

Connecting out means a server behind a firewall or a home router joins without a port
being opened to it, and a server you add once is seen by every window and device, with
nothing to set up on each.

## Why put a folder on a server

That buys three things. The agents on a server keep working while your Mac sleeps, loses
its network, or has the window closed, because nothing they need is on the Mac. The work
can happen on Linux, or on a machine with more room than a laptop. And the Mac stays quiet
while four agents build at once somewhere else.

When a machine is offline, its folders show what the app last knew, marked as not current,
and the app does not take a prompt or an answer for them that it cannot deliver. A machine
that loses its connection keeps its agents working, and reconnects by itself when it can.
When it does, you see everything that happened meanwhile. A machine never stops for being
idle, so it is still there for the next connection.

If your control plane runs on your Mac, a server's agents keep working while the Mac
sleeps, but you cannot see or answer them until the Mac is back. Running the control plane
as copies on hosting of your own removes that gap; see
[Run the control plane as several copies](../how-to/run-several-copies.md).

## Why worktrees

Every agent in a folder works in the folder unless you say otherwise. Two
agents changing code at once are then changing the same files: one's half-finished edit
breaks the other's build, a test run picks up both sets of changes, and nobody can say
afterwards which change came from which agent.

A git worktree is a second checkout of the same repository, in its own folder, on its own
branch, sharing one history. Changes made in one stay out of the others until someone
merges them. So when a folder is a git repository, you can start an agent in a new
worktree, or send it into one that already exists, for instance to review what another
agent did there.

Each runtime has a worktree option of its own, but none of them could be relied on when
the app starts them. What every runtime does honour is the folder the app starts it in. So
the app makes the worktree itself and starts the agent there. The behaviour is the same
whichever runtime you pick.

A new worktree is named from the first few words of the prompt that starts it, and its
branch has the same name under `agents/`. It starts from the commit your folder
has checked out, and it lives inside the repository, under `.agents/worktrees`. An agent
in a worktree is still listed in the same folder, with the worktree's name on its row.
An agent that starts helpers of its own can put each one in a worktree too.

A folder has one set of pins, whichever checkout its agents work in. When an agent in a
worktree pins a page, the app writes it to `.agents/pins.json` in the folder, never
the worktree's copy, and it never reads a worktree's copy either. The app doesn't commit
this file: a changed pin shows in the folder's changes and goes in with whatever is
committed there next. See [Pin a page to a folder](../how-to/pin-a-page-to-a-folder.md).

## An agent can change where it works

Where an agent works is not fixed when it starts. An agent that finds its task has grown
into something that needs its own branch can move into a worktree, or you can move it, and
it can move back to the folder later. The app makes the move between turns, because
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

## A folder is in a project

A project is what people work on (#2317). It is a record on the control plane, and it joins
folders on any number of machines. The same repository cloned on three machines is three
folders in one project.

A folder names its project in its own `.agents/folder.json`:

```json
{
  "project": "p-1wzbuhd43kd9"
}
```

When the folder is a Git repository, that line travels with Git. A clone on another machine
joins the same project with nothing to set. The control plane makes a record for an id that
it does not know yet, with the folder's name.

You see no new step. A folder that names no project gets one of its own name when you add it,
or when its machine next starts. You pick another project in Folder Settings ▸ General ▸
Project on the Mac, or with **Project…** in the folder's menu on the iPhone, iPad and web
page.

A project is not a repository. The repository only carries `.agents/` between clones. Later,
a project's tracker, code review and CI, and its reports, belong to the project, not to one
clone (#2669, #2670).

## Worktrees are never removed by accident

Archiving an agent never throws work away. When you archive the last agent in a worktree
the app made, the worktree's folder goes only if everything in it is committed, and its
branch goes only if it has been merged. Otherwise both are left exactly as they are.

You can also remove a worktree yourself. The app refuses while an agent is working in it,
and tells you what would be lost, and asks you to confirm, if it has changes that are not
committed or a branch that is not merged.

## Your own set, and a folder's

A folder can carry its own `.agents` folder, with skills, instructions and plugins that
belong to that folder and apply only inside it. A plugin there that is new or has changed
waits for your OK on the folder's page before any agent is handed it — the same check as
a workflow file — because it can run hooks and connectors when a session starts. See
[A folder's own plugins](../how-to/share-skills-across-agents.md#a-folders-own-plugins).
`~/.agents` in your home folder is the same idea one level up: your own set, which every
agent the app starts gets, in every folder and on every runtime. The app lays it out on
your Mac only; a folder on a server gets the folder's own folder, and the runtimes on
the server keep whatever they were set up with there.

Your set goes to each runtime the way that runtime can take it, which differs. Some read
`~/.agents/skills` themselves; for others the app places links, which it never puts back
once you delete them; connectors go with each conversation as it starts, so nothing is
written into a runtime's own config. **Settings ▸ Agent Configuration** shows what each runtime ends up
with. See [Share skills, instructions and connectors with every agent](../how-to/share-skills-across-agents.md).

A folder's instructions, skills, connectors and plugins are set up in **Folder Settings ▸
Agent Configuration**, a sheet opened from the folder page's toolbar, the folder's context
menu in the sidebar, or **File ▸ Folder Settings…** (Option-Command-comma). Its pages are the
same as **Settings ▸ Agent Configuration**: Overview, Instructions, Skills, Connectors,
Plugins and Other files, between the folder's own **General** and **Worktrees**. The folder
is the difference: yours is `~/.agents`, the folder's is its `.agents`, and its instructions
are `AGENTS.md` at the top of the folder. A folder's Overview counts what is there, where
yours also shows what each runtime gets. Because that folder is committed,
a skill added there reaches everyone who clones the folder; one added in **Settings ▸ Agent Configuration**
is yours alone. A worktree has its own `.agents`, so a change there stays on that branch until
it is merged. **General** also holds the folder's two limits on agents that other agents start: how many may be running (3 unless you change it) and how many may be kept until you archive them (5). They are saved in the folder's own `.agents/folder.json`, so they go wherever the folder goes. A change to that file, or to `.agents/pins.json`, made outside the app is not used until you keep it there; see [Settings](../reference/settings.md). See [Agent tools](../reference/agent-tools.md). On a server, Folder Settings shows only **General**. See
[Add a skill from a catalogue](../how-to/add-a-skill-from-a-catalogue.md).

A folder's connectors (MCP servers) live in `.agents/mcp.json`, on that same page. The file is committed, so it names each secret as `${NAME}` and never
holds the value. Each person sets their own in `~/.agents-secrets/secrets.env`, a folder apart from `~/.agents` and readable only by them, because `~/.agents` is settings a person may copy or commit and a secret is not. A connector added from
the sheet is approved as it goes in. One that arrives with a pull waits, marked **waiting
for your OK**, until you choose **Approve**; no agent is given it before that. Where you and
the folder both have a connector of the same name, agents in the folder get the folder's. A
missing secret is named on the row, and agents start without that connector rather than with an
empty key. Folders on a server don't show the section. See
[Add a connector from the registry](../how-to/add-a-connector-from-the-registry.md).

Nothing from a catalogue is taken on trust. skills.sh does not review what it lists, so the
app shows every file before anything is written, points out scripts an agent could run, pins
the commit it took, and checks each file against GitHub's own record of it at that commit.

## Related

- [Add a folder](../how-to/add-a-folder.md), [Add a machine](../how-to/add-a-machine.md)
  and [Start an agent in its own worktree](../how-to/start-in-a-worktree.md).
- [The control plane](control-plane.md).
- [Give an agent more folders and connectors](../how-to/give-an-agent-more-folders.md).
- [Settings and the Resources page](../reference/settings.md).
