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
**General**; then **Agent Runtimes**, **Spending** and **Pool**; then **Shared**; then
**Devices** and **Servers**. **Agent Runtimes** and **Shared** are headings: each runtime
has its own page under **Agent Runtimes**, and Shared's pages (Overview, Instructions,
Skills, and the rest) sit under **Shared**, each with a count and a warning sign on any
that needs a look. The window opens at one size and stays there whichever pane you choose,
so it never jumps. You can resize it larger; it will not go smaller than the size it opens
at. Agents on iPhone and iPad has no Settings screen of its own; it follows the Mac it is
paired with.

| Device | Pane | Control | What it does |
| --- | --- | --- | --- |
| Mac | General | **Appearance**: **System**, **Light**, **Dark** | Sets the app's look. **System** follows your Mac, and changes with it. |
| Mac | General | **Sleep**: **Keep this Mac awake while agents are working**, and **After they stop** | On (the default): the daemon holds the Mac awake while an agent is working, then for the time below once the last one stops, so you can reply. Off: the Mac sleeps on its own schedule, including mid-turn; the time you chose is kept and the menu is dimmed. **After they stop** is **Right away**, then **1 hour** through **8 hours**. The default is **1 hour**. The screen can still sleep. At 20% battery or below the hold ends anyway. A server has no idle sleep to hold off, and the phone has no control for this. |
| Mac | General | **Archived agents** | How many archived agents there are and how much space they take, and how long they are kept. When they are over the space they may take and nothing more can be retired yet, it says so and why. |
| Mac | General | **Keep archived agents**: **7 days**, **14 days**, **30 days**, **90 days**, **Forever** | How long an archived agent is kept before it is retired: its conversation is deleted and a short record of who it was is kept. The default is **30 days**. If a change would retire agents at once, you are asked first, with how many and how much space it frees. Each server keeps to the same setting. |
| Mac | General | **Up to**: **1 GB**, **2 GB**, **5 GB**, **10 GB**, **No limit** | The most space archived agents may take. Over it, the ones archived longest ago are retired first. The default is **2 GB**. **Forever** with **No limit** keeps archived agents for good. |
| Mac | Agent Runtimes ▸ each runtime | Runtime status and install controls | Each runtime has its own page. It says where the runtime is, **Not on this Mac** (with the download's size where the app fetches it), or what it is doing while it installs, with **Install**, **Retry** after an install failed, **Update** when the app carries a newer version of one it installed, or **Open install page**. Claude's page says whether it runs from the app's own folder, with nothing added to your PATH, or through your own Node. |
| Mac | Agent Runtimes ▸ each runtime | **Allowance**, with **Mark available** when it is out | Where the runtime's allowance stands: **Available**, **Rate limited · trying again at** a time, **Out · reset** a time **· checking after** a time, **Out since** a time **· checking after** a time, or **Credit used up · checking after** a time. Under it, where the runtime says so, what is left of its plan, such as **28% left this week · resets Sun 20:39 · as of 14:02**. **Mark available** says it is back before a check does. It is shown only: a chat on an out runtime can still be sent a message. See [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md). |
| Mac | Agent Runtimes ▸ Cursor / Grok | **Permission mode**, **Default** or **Always-approve** | How that runtime asks permission. **Default** asks before it does something that needs permission. **Always-approve** answers every permission request for you; questions that are not permission still wait. Each control is independent, survives quitting, and applies to every agent on that runtime — including ones started by a workflow or on a server. The control is still there when the runtime is not installed. Claude, Codex, Gemini, Antigravity and Copilot keep the permission modes they already have under the prompt. |
| Mac | Agent Runtimes | **Install your agents** (a sheet at start-up) | Shown when the app starts and a runtime it can install is not on this Mac, with the same rows. **Not now** or **Done** puts it away; it comes back only for a runtime it has not offered before. A runtime that is installed but signed out does not count as missing. |
| Mac | Agent Runtimes ▸ Gemini | **Paste a Gemini key**, **Save**, **Check again**, **Replace…**, **Remove** | The Gemini API key Gemini agents sign in with, on this Mac and on servers: Google's own sign-in no longer works for individuals. It starts `AIza` or `AQ.`, from aistudio.google.com/apikey. It says **Works**, **Checking…**, **No key**, or that Gemini refused it and why. Kept in this Mac's Keychain. It is lent to a server only while an agent runs there, and never written on the server; the same key is shown under **Runtime credentials** in **Servers**. |
| Mac | Shared | **Overview** | What every agent gets from `~/.agents`: a grid of instructions, skills, MCP servers and plugins by runtime, with a count or a tick where it gets them, **n of m** where some are left out, **—** where it has no way to take them and **?** where it is not checked yet. **Needs a look** lists each clash, anything left out and any runtime with no way in, and opens its page. **Reveal in Finder** opens `~/.agents`. |
| Mac | Shared | **Instructions**, **Skills**, **MCP servers**, **Plugins**, **Other files** | One page each: what is there, and how each runtime gets it. **Skills** shows a skill's `SKILL.md`, has **Add skill…** to search skills.sh and add one, and for a skill added from a catalogue shows **From** and **Taken at**, an **update** mark when its source has changed, and **Update…** and **Remove…** (see [Add a skill from a catalogue](../how-to/add-a-skill-from-a-catalogue.md)); **MCP servers** shows your servers, the app's own and those only in one runtime's own config, with env and header names but never their values, and says so when `mcp.json` cannot be read. **Add server…** searches the MCP Registry; a server the app added shows **registry** and its version, and has **Set…**, **Replace…** and **Remove…** (see [Add an MCP server from the registry](../how-to/add-an-mcp-server-from-the-registry.md)). A secret that is not set is named, and agents start without that server. **Plugins** shows what each contains. **Edit** opens the file in your editor. See [Share skills, instructions and servers with every agent](../how-to/share-skills-across-agents.md). |
| Mac | Spending | **Per agent**, with an amount, a currency, **Set** and **No limit** | The most one agent may spend across its whole life, not one turn. An agent that reaches it finishes the turn it is in and takes no further prompt, so it may end a little over. If agents have already spent this much, the pane says so as you set it. |
| Mac | Spending | **Per day**, with an amount, a currency, **Set** and **No limit** | The most everything may spend in one local day, in every project. When the day reaches it, nothing new starts and no prompt is sent, including a workflow on a schedule. Whatever is working finishes its turn and holds. What you typed waits until the day rolls over. Each server keeps to this limit on its own. |
| Mac | Spending | **Today** | What today has cost so far, and how much is left under **Per day**. Shows **Nothing yet** before anything is spent. |
| Mac | Spending | **What the limits have stopped** | The agents that reached a limit, with what each spent. Shown only when there are some. |
| Mac | Devices | The list of devices | Every iPhone and iPad that has paired, with one line on each: **Paired**, **Last heard from** a time, **Has not said whether it can show notifications**, or **Notifications are off on the device — it will not be chosen**. A device is told when an agent needs you and your Mac is not in use. **Forget…** cuts a device off. |
| Mac | Devices | **Pair a Device…** | Shows a code to scan with Agents on an iPhone or iPad, on the Mac's Wi‑Fi. It works for five minutes or one device, and stops when you close it. |
| Mac | Servers | The list of servers | Every server you have added, with its projects, whether it is connected, **Connecting…**, **Offline since** a time, **Update waiting — an agent is mid-turn** or what went wrong, its system, the version of Agents on it, and the runtimes installed there. Claude and Codex on a server use this Mac’s own sign-ins, through this Mac; nothing of them is written on a server. |
| Mac | Servers | **Add Server** | Adds a server by the name you use with `ssh`. |
| Mac | Servers | **Check again** | Shown on the selected server. Tries connecting to it again. |
| Mac | Servers | **Remove…** | Shown on the selected server. Removes it from the app, stopping any agents running there. Its folders are not touched. **Also delete what Agents installed on** the server removes the app's own files there too. |
| Mac | Servers | **Use this server's own sign-in only** | Shown on the selected server. Agents there use Claude, Codex and Gemini as signed in on the server: this Mac's sign-ins aren't relayed to it, and nothing from Settings is lent to it. |
| iPhone and iPad | Settings ▸ Agents | **Local Network** | Lets the app find your Mac on the network you are both on. Without it, the app cannot reach your Mac. |
| iPhone and iPad | Settings ▸ Agents | **Notifications** | Lets the Mac tell this device when an agent needs you. When it is off, the Mac's **Devices** pane says so and the device is not chosen. |

## Resources

**Resources** is not a Settings pane. It is a page of its own, opened from **View ▸
Resources** (Option-Command-L) or the **Resources** row at the foot of the projects
column. It lists every shared resource on this Mac — each simulator, each installed
browser, and the screen — whether it is free, who holds it and since when, when the
lease runs out, and who is waiting. You can end a lease or take an agent out of a line
from here. See [Leases on shared resources](../explanation/leases.md).

When an agent reaches a spending limit, **Raise the limit** above the prompt opens the
Settings window.

## See also

- [Limit what agents spend](../how-to/limit-spending.md)
- [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)
- [Add a Linux server](../how-to/add-a-linux-server.md)
- [Leases on shared resources](../explanation/leases.md)
- [Statuses and groups](statuses.md)
- [Runtimes](runtimes.md)
