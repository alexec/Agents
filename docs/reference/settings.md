---
diataxis: reference
devices: [mac, iphone, ipad]
description: Every control in Agents ▸ Settings on the Mac, the Resources page, and the system settings Agents uses on iPhone and iPad.
---

# Settings and the Resources page

This page lists every control in the Mac's Settings window, **Agents ▸ Settings…**, pane
by pane, the **Resources** page (not in that window), and the system settings the app on
iPhone and iPad depends on.

The Mac's Settings window has seven panes, chosen from one rail down its left side:
**Appearance**; then **Agent Runtimes**, **Spending** and **Pool**; then **Shared**,
a heading with its pages always listed under it, each with a count, and a warning sign on
any that needs a look; then **Devices** and **Servers**. The window stays the same
size whichever pane you choose. Agents on iPhone and iPad has no Settings screen of its
own; it follows the Mac it is paired with.

| Device | Pane | Control | What it does |
| --- | --- | --- | --- |
| Mac | Appearance | **Appearance**: **System**, **Light**, **Dark** | Sets the app's look. **System** follows your Mac, and changes with it. |
| Mac | Appearance | **Archived agents** | How many archived agents there are and how much space they take, and how long they are kept. When they are over the space they may take and nothing more can be retired yet, it says so and why. |
| Mac | Appearance | **Keep archived agents**: **7 days**, **14 days**, **30 days**, **90 days**, **Forever** | How long an archived agent is kept before it is retired: its conversation is deleted and a short record of who it was is kept. The default is **30 days**. If a change would retire agents at once, you are asked first, with how many and how much space it frees. Each server keeps to the same setting. |
| Mac | Appearance | **Up to**: **1 GB**, **2 GB**, **5 GB**, **10 GB**, **No limit** | The most space archived agents may take. Over it, the ones archived longest ago are retired first. The default is **2 GB**. **Forever** with **No limit** keeps archived agents for good. |
| Mac | Agent Runtimes | The list of runtimes | Every runtime the app knows, each saying where it is, **Not on this Mac** (with the download's size where the app fetches it), or what it is doing while it installs, with **Install**, **Retry** after an install failed, **Update** when the app carries a newer version of one it installed, or **Open install page**. Under the list, where Claude is: in the app's own folder, with nothing added to your PATH, or run through your own Node. The others use their makers' own installers. |
| Mac | Agent Runtimes | Under **Cursor** and **Grok**: **permission mode**, **Default** or **Auto-review** | How that runtime asks permission. **Default** asks before it does something that needs permission. **Auto-review** allows ordinary work inside the project and asks before anything that leaves it, publishes, or needs extra privilege. Each control is independent, survives quitting, and applies to every agent on that runtime — including ones started by a workflow or on a server. The control is still there when the runtime is not installed. Claude, Codex, Gemini, Antigravity and Copilot keep the permission modes they already have under the prompt. |
| Mac | Agent Runtimes | **Install your agents** (a sheet at start-up) | Shown when the app starts and a runtime it can install is not on this Mac, with the same rows. **Not now** or **Done** puts it away; it comes back only for a runtime it has not offered before. A runtime that is installed but signed out does not count as missing. |
| Mac | Agent Runtimes | Under **Gemini**: **Paste a Gemini key**, **Save**, **Check again**, **Replace…**, **Remove** | The Gemini API key Gemini agents sign in with, on this Mac and on servers: Google's own sign-in no longer works for individuals. It starts `AIza` or `AQ.`, from aistudio.google.com/apikey. It says **Works**, **Checking…**, **No key**, or that Gemini refused it and why. Kept in this Mac's Keychain. The same key is shown under **Runtime credentials** in **Servers**. |
| Mac | Shared | **Overview** | What every agent gets from `~/.agents`: a grid of instructions, skills, MCP servers and plugins by runtime, with a count or a tick where it gets them, **n of m** where some are left out, **—** where it has no way to take them and **?** where it is not checked yet. **Needs a look** lists each clash, anything left out and any runtime with no way in, and opens its page. **Reveal in Finder** opens `~/.agents`. |
| Mac | Shared | **Instructions**, **Skills**, **MCP servers**, **Plugins**, **Other files** | One page each: what is there, and how each runtime gets it. **Skills** shows a skill's `SKILL.md`, has **Add skill…** to search skills.sh and add one, and for a skill added from a catalogue shows **From** and **Taken at**, an **update** mark when its source has changed, and **Update…** and **Remove…** (see [Add a skill from a catalogue](../how-to/add-a-skill-from-a-catalogue.md)); **MCP servers** shows your servers, the app's own and those only in one runtime's own config, with env and header names but never their values, and says so when `mcp.json` cannot be read. **Add server…** searches the MCP Registry; a server the app added shows **registry** and its version, and has **Set…**, **Replace…** and **Remove…** (see [Add an MCP server from the registry](../how-to/add-an-mcp-server-from-the-registry.md)). A secret that is not set is named, and agents start without that server. **Plugins** shows what each contains. **Edit** opens the file in your editor. See [Share skills, instructions and servers with every agent](../how-to/share-skills-across-agents.md). |
| Mac | Spending | **Per agent**, with an amount, a currency, **Set** and **No limit** | The most one agent may spend across its whole life, not one turn. An agent that reaches it finishes the turn it is in and takes no further prompt, so it may end a little over. If agents have already spent this much, the pane says so as you set it. |
| Mac | Spending | **Per day**, with an amount, a currency, **Set** and **No limit** | The most everything may spend in one local day, in every project. When the day reaches it, nothing new starts and no prompt is sent, including a workflow on a schedule. Whatever is working finishes its turn and holds. What you typed waits until the day rolls over. Each server keeps to this limit on its own. |
| Mac | Spending | **Today** | What today has cost so far, and how much is left under **Per day**. Shows **Nothing yet** before anything is spent. |
| Mac | Spending | **What the limits have stopped** | The agents that reached a limit, with what each spent. Shown only when there are some. |
| Mac | Pool | **Carry chats on with the next runtime when one runs out** | When a chat's allowance runs out, it carries on with the next runtime in the pool that isn't out, with the conversation so far and the message it was refused. Off, a chat stops as before. Needs two runtimes or more. See [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md). |
| Mac | Pool | The pool, in the order to try: each runtime with how it is paid for, **Model** and **Remove** | Drag to reorder. **Model** is the model a chat starts on when it moves to that runtime and no Matching models level decides. A runtime that is not signed in stays in the pool and is skipped. |
| Mac | Pool | **Add a runtime** | Adds a runtime on its own plan. Only runtimes installed and signed in are offered. |
| Mac | Pool | **Add credit on an API key…** | Adds a key on **Free tier**, **Free credit** or **Prepaid, with auto-recharge off**, with an amount and expiry for credit. **Billed with no limit** is shown and cannot be picked. Only a key this Mac lends, today Gemini's, and only once it is saved in **Agent Runtimes**. It goes last. |
| Mac | Devices | The list of devices | Every iPhone and iPad that has paired, with one line on each: **Paired**, **Last heard from** a time, **Has not said whether it can show notifications**, or **Notifications are off on the device — it will not be chosen**. A device is told when an agent needs you and your Mac is not in use. **Forget…** cuts a device off. |
| Mac | Devices | **Pair a Device…** | Shows a code to scan with Agents on an iPhone or iPad, on the Mac's Wi‑Fi. It works for five minutes or one device, and stops when you close it. |
| Mac | Servers | The list of servers | Every server you have added, with its projects, whether it is connected, **Connecting…**, **Offline since** a time, **Update waiting — an agent is mid-turn** or what went wrong, its system, the version of Agents on it, and the runtimes installed there. |
| Mac | Servers | **Add Server** | Adds a server by the name you use with `ssh`. |
| Mac | Servers | **Check again** | Shown on the selected server. Tries connecting to it again. |
| Mac | Servers | **Remove…** | Shown on the selected server. Removes it from the app, stopping any agents running there. Its folders are not touched. **Also delete what Agents installed on** the server removes the app's own files there too. |
| Mac | Servers | **Runtime credentials**: for Gemini, **Paste a Gemini key**, **Save**, **Check again**, **Replace…**, **Remove** | Gemini's key signs in Gemini agents here and on servers. It says **Works**, **Checking…**, **No key**, or that Gemini refused it and why. Kept in this Mac's Keychain, never written on a server, and lent to a server only while an agent runs there. Claude and Codex take nothing here: on a server they sign in through this Mac's own sign-ins. See [Add a Linux server](../how-to/add-a-linux-server.md). |
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
