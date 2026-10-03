---
diataxis: reference
devices: [mac, iphone, ipad]
description: Every control in Agents ▸ Settings on the Mac, the Resources page, and the system settings Agents uses on iPhone and iPad.
---

# Settings and the Resources page

This page lists every control in the Mac's Settings window, **Agents ▸ Settings…**, pane
by pane, the **Resources** page (not in that window), and the system settings the app on
iPhone and iPad depends on.

The Mac's Settings window has panes chosen from one rail down its left side:
**General**; then **Agent Runtimes** and **Spending**; then **Shared**; then
**Control plane**. **Agent Runtimes** and **Shared** are headings: each runtime
has its own page under **Agent Runtimes**, and Shared's pages (Overview, Instructions,
Skills, and the rest) sit under **Shared**, each with a count and a warning sign on any
that needs a look. The window opens at one size and stays there whichever pane you choose,
so it never jumps. You can resize it larger; it will not go smaller than the size it opens
at. Agents on iPhone and iPad has no Settings screen of its own; it follows the Mac it is
paired with.

| Device | Pane | Control | What it does |
| --- | --- | --- | --- |
| Mac | General | **Appearance**: **System**, **Light**, **Dark** | Sets the app's look. **System** follows your Mac, and changes with it. |
| Mac | General | **You**: **What agents call you**, and **Pronouns** | The name every agent is told to use for you, and to use for itself by its runtime's name, in questions above all: "Claude (this agent) will…", "Alex, do you want…?", never a bare "I" or "you". Blank uses the first word of your Mac account's full name, shown as the placeholder. Without pronouns, agents use your name or "they". Each server is given the same name and pronouns. Told to an agent once, before its first turn, so one already started keeps what it was told. |
| Mac | General | **Sleep**: **Keep this Mac awake while agents are working**, and **After they stop** | On (the default): the daemon holds the Mac awake while an agent is working, then for the time below once the last one stops, so you can reply. Off: the Mac sleeps on its own schedule, including mid-turn; the time you chose is kept and the menu is dimmed. **After they stop** is **Right away**, then **1 hour** through **8 hours**. The default is **1 hour**. The screen can still sleep. At 20% battery or below the hold ends anyway. A server has no idle sleep to hold off, and the phone has no control for this. |
| Mac | General | **Archived agents** | How many archived agents there are and how much space they take, and how long they are kept. When they are over the space they may take and nothing more can be retired yet, it says so and why. |
| Mac | General | **Keep archived agents**: **7 days**, **14 days**, **30 days**, **90 days**, **Forever** | How long an archived agent is kept before it is retired: its conversation is deleted and a short record of who it was is kept. The default is **30 days**. If a change would retire agents at once, you are asked first, with how many and how much space it frees. Each server keeps to the same setting. |
| Mac | General | **Up to**: **1 GB**, **2 GB**, **5 GB**, **10 GB**, **No limit** | The most space archived agents may take. Over it, the ones archived longest ago are retired first. The default is **2 GB**. **Forever** with **No limit** keeps archived agents for good. |
| Mac | Agent Runtimes ▸ each runtime | Runtime status and install controls | Each runtime has its own page. It says where the runtime is, **Not on this Mac** (with the download's size where the app fetches it), or what it is doing while it installs, with **Install**, **Retry** after an install failed, **Update** when the app carries a newer version of one it installed, or **Open install page**. Claude's page says whether it runs from the app's own folder, with nothing added to your PATH, or through your own Node. Where its allowance stands is on the **Runtimes** page, under Activity. |
| Mac | Agent Runtimes ▸ Cursor / Grok | **Permission mode**, **Default** or **Always-approve** | How that runtime asks permission. **Default** asks before it does something that needs permission. **Always-approve** answers every permission request for you; questions that are not permission still wait. Each control is independent, survives quitting, and applies to every agent on that runtime — including ones started by a workflow or on a server. The control is still there when the runtime is not installed. Claude, Codex, Gemini, Antigravity and Copilot keep the permission modes they already have under the prompt. |
| Mac | Agent Runtimes ▸ each runtime | **Command sandbox**: **As configured by runtime**, **On**, **Off** | Whether the runtime runs its commands in its own sandbox, for every agent on it that has no choice of its own. **As configured by runtime** (the default) adds nothing, so the runtime's own settings decide. **On** limits what commands can write, and, where the runtime's sandbox covers it, the network; **Off** lets them run with your own access. Neither changes the permission mode, and the app's own folder and tool rules apply either way. Claude and Grok have all three. Codex's **Off** is its **Full access** mode, which also stops its approval prompts, and **On** takes it out of Full access. Gemini has no **On**: its sandbox cannot start when the app runs it. Cursor and Copilot say **Runtime controlled**, because only their own settings reach their sandbox; Antigravity and OpenCode say **No sandbox**. A change applies from each agent's next turn, on this Mac and on servers. One agent's own choice is the sandbox capsule under its prompt; see [Choose a runtime, model and mode](../how-to/choose-runtime-model-mode.md). |
| Mac | Agent Runtimes | **Install your agents** (a sheet at start-up) | Shown when the app starts and a runtime it can install is not on this Mac, with the same rows. **Not now** or **Done** puts it away; it comes back only for a runtime it has not offered before. A runtime that is installed but signed out does not count as missing. |
| Mac | Agent Runtimes ▸ Gemini | **Paste a Gemini key**, **Save**, **Check again**, **Replace…**, **Remove** | The Gemini API key Gemini agents sign in with, on this Mac and on servers: Google's own sign-in no longer works for individuals. It starts `AIza` or `AQ.`, from aistudio.google.com/apikey. It says **Works**, **Checking…**, **No key**, or that Gemini refused it and why. Kept in this Mac's Keychain. It is lent to a server only while an agent runs there, and never written on the server; nothing of it is kept by the control plane. |
| Mac | Shared | **Overview** | What every agent gets from `~/.agents`: a grid of instructions, skills, MCP servers and plugins by runtime, with a count or a tick where it gets them, **n of m** where some are left out, **—** where it has no way to take them and **?** where it is not checked yet. **Needs a look** lists each clash, anything left out and any runtime with no way in, and opens its page. **Reveal in Finder** opens `~/.agents`. |
| Mac | Shared | **Instructions**, **Skills**, **MCP servers**, **Plugins**, **Other files** | One page each: what is there, and how each runtime gets it. **Skills** shows a skill's `SKILL.md`, has **Add skill…** to search skills.sh and add one, and for a skill added from a catalogue shows **From** and **Taken at**, an **update** mark when its source has changed, and **Update…** and **Remove…** (see [Add a skill from a catalogue](../how-to/add-a-skill-from-a-catalogue.md)); **MCP servers** shows your servers, the app's own and those only in one runtime's own config, with env and header names but never their values, and says so when `mcp.json` cannot be read. **Add server…** searches the MCP Registry; a server the app added shows **registry** and its version, and has **Set…**, **Replace…** and **Remove…** (see [Add an MCP server from the registry](../how-to/add-an-mcp-server-from-the-registry.md)). A secret that is not set is named, and agents start without that server. **Plugins** shows what each contains. **Edit** opens the file in your editor. See [Share skills, instructions and servers with every agent](../how-to/share-skills-across-agents.md). |
| Mac | Spending | **Per agent**, with an amount, a currency, **Set** and **No limit** | The most one agent may spend across its whole life, not one turn. An agent that reaches it finishes the turn it is in and takes no further prompt, so it may end a little over. If agents have already spent this much, the pane says so as you set it. |
| Mac | Spending | **Per day**, with an amount, a currency, **Set** and **No limit** | The most everything may spend in one local day, in every project. When the day reaches it, nothing new starts and no prompt is sent, including a workflow on a schedule. Whatever is working finishes its turn and holds. What you typed waits until the day rolls over. Each server keeps to this limit on its own. |
| Mac | Spending | **Today** | What today has cost so far, and how much is left under **Per day**. Shows **Nothing yet** before anything is spent. |
| Mac | Spending | **What the limits have stopped** | The agents that reached a limit, with what each spent. Shown only when there are some. |
| Mac | Control plane ▸ Clients | The list of clients | Every window, device and browser paired with the control plane, each of which may do everything, and how it reaches the control plane now: **connected directly**, **connected through** a Mac **(iCloud relay)**, or when it was last seen. **Forget…** cuts a client off at once, directly and through the relay. Any client may be forgotten, the last one too. See [Connect a window or phone](../how-to/connect-a-window-or-phone.md). |
| Mac | Control plane ▸ Clients | **Pair a Device…** | Shows a code to scan with Agents on an iPhone or iPad. It pairs one device within five minutes, and stops working when you close it. |
| Mac | Control plane ▸ Clients | **Pair a Mac…** | A code to paste into Agents on another Mac. That window can then do all this one can. |
| Mac | Control plane ▸ Hosts | The list of hosts | This Mac and every server that runs agents for the control plane, online or offline, with **Check again** and **Remove…**. See [Add a server](../how-to/add-a-server.md). |
| Mac | Control plane ▸ Hosts | **Add a Server…**, **Add by Code…** | A command to run on a Linux server, or an install over ssh; a code for another Mac's Agents Host. |
| Mac | Project Settings ▸ General | **Helpers running**, **1** to **10**, and **Helpers not archived**, **1** to **20** | Limits on agents that other agents start in this project with `start_agent`, counted across the whole project. **Helpers running** (default **3**) counts the ones working, waiting on a question or permission, starting, or waiting to carry on by themselves (blocked on other agents or a time, waiting on events, or waiting for an allowance); finished, stopped, parked and archived ones do not count. **Helpers not archived** (default **5**) counts every one you have not archived. A start that would go over either is refused, and the agent is told which limit and which agents hold it. Choosing the value marked **(default)** puts the project back to it. Running can't be set higher than not archived. Lowering a limit stops nothing; it refuses the next start. Only a person can change these, from the window or any paired phone or browser: agents and workflows can't. Opened with **File ▸ Project Settings…** (Option-Command-comma); on a server it is set on that server. |
| Mac | Project Settings ▸ General | **Helpers archived**: **Agents may archive the helpers they started**, on or off | Whether an agent may archive, with `archive_agent`, an agent it started in this project once that agent has stopped working, which frees its not-archived place. On by default. Never itself, never your sessions and never another agent's helpers; you can bring any of them back from **Archived**. Off, `archive_agent` is refused and only you archive. Only a person can change this, from the window: agents and workflows can't. |
| iPhone and iPad | Settings ▸ Agents | **Local Network** | Lets the app reach a control plane on the network you are both on, such as the one on your Mac. Without it, the app reaches it only through the relay. |
| iPhone and iPad | Settings ▸ Agents | **Notifications** | Lets the Mac tell this device when an agent needs you. When it is off, the device is not chosen. |

## Runtimes

**Runtimes** is not a Settings pane either. It is a page under **Activity**, at the foot
of the projects column, and it says where every runtime this app knows stands: whether it
is on this Mac, and where its allowance is, as **Available**, **Rate limited · trying
again at** a time, **Out · reset** a time **· checking after** a time, **Out since** a
time **· checking after** a time, or **Credit used up · checking after** a time. Under
it, where the runtime says so, what is left of its plan, such as **28% left this week ·
resets Sun 20:39 · as of 14:02**. **Mark available** says it is back before a check does,
and asks nothing first, because a wrong mark costs one refused turn. It is shown only: a
chat on an out runtime can still be sent a message. The row in the sidebar says how many
are out, with a red dot, and says nothing when none are. See
[Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md).

Above the prompt, the runtime chooser is in the same two runs. A runtime whose allowance
is spent is still listed, under **Out**, and can still be picked, so the way back to it is
there when it recovers. What it says under the name is the same line the page gives.

## Resources

**Settings ▸ Resources** is where you declare resources: things agents should take turns
with that the app can't find by itself, such as **build**. Each has:

- a **name**, which agents lease it by;
- a **description**, which agents read in `list_resources` and their briefing, and are
  told to follow: they lease the resource whenever it applies to what they are about to do;
- **Held by**: how many agents may hold it at once, 1 by default. With 2 or more, that many
  hold it together and the rest wait in line, in order;
- a **usual length** and a **longest** length for a lease on it, in minutes. Left blank,
  they are the app's own: 30 and 240.

**Add Resource…** declares one, **Edit…** changes it, and **Remove** stops declaring it.
Anyone holding a resource you remove or shrink keeps the lease until they release it. The
screen, simulators and browsers are listed under **Found on this Mac**, read-only: one
agent at a time each. Declared resources belong to this Mac's host, kept in its folder
beside its leases, because how many builds a machine can take is that machine's.

The **Resources page** is not a Settings pane. It is a page of its own, opened from
**View ▸ Resources** (Option-Command-L) or the **Resources** row at the foot of the
projects column. It lists the declared resources first, free or held, with their
descriptions, then every resource found on this Mac — each simulator, each installed
browser, and the screen — whether it is free, who holds it and since when, when the lease
runs out, and who is waiting. A declared resource more than one agent may hold says
"2 of 3 held" and names each holder. You can end a lease or take an agent out of a line
from here. See [Leases on shared resources](../explanation/leases.md).

On iPhone and iPad, **Resources** under **Activity** shows the same list read-only, and so
does **Resources** under each host on the web page. Declaring, editing and ending leases
are on the Mac.

When an agent reaches a spending limit, **Raise the limit** above the prompt opens the
Settings window.

## See also

- [Limit what agents spend](../how-to/limit-spending.md)
- [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)
- [Add a server](../how-to/add-a-server.md)
- [Leases on shared resources](../explanation/leases.md)
- [Statuses and groups](statuses.md)
- [Runtimes](runtimes.md)
