# Settings by subject (#2157)

Amends FR-022. Settings were grouped by scope (This device, You, Control plane, #1759).
"You" held three subjects (the person, the machines, what follows the person), and on the
Mac "This device" and "Machines ▸ This Mac" both meant the Mac. Alex (2026-10-21) named three
subjects: this client, the machines, and the control plane. Settings are now grouped by them,
the same on all three clients.

## The groups

| Group | Its subject | Mac | Remote | Web |
|---|---|---|---|---|
| **This app** (web: **This browser**) | how this client draws | Appearance, Sidebar | Appearance, Notifications, Sidebar | Appearance, Sidebar, Finished chats |
| **Machines** | the machines that run agents | Machines, Agent Runtimes, Agent Configuration, Cost, Resources, Secrets | Machines, Secrets | Git access, Machines, Backups, Servers' backups, The same on all your machines, Secrets |
| **Control plane** | what the control plane keeps | Account, Sign-ins, People, Groups, Channels, Sign-In, Workspace Providers, Clients, Overview | Sign-ins, People, Channels, Sign-In, Groups, Workspace providers | Sign-ins, People, Groups, Channels, Sign-In, Workspace providers |

Sidebar and Finished chats are kept on the Mac's host so that every client draws the same
(#2079), but what they change is how the app draws, so they are under This app.

## Frames

The Mac's rail:

```
This app
  Appearance
  Sidebar
Machines
  Machines
  Agent Runtimes
  Agent Configuration
  Cost
  Resources
  Secrets
Control plane
  Account
  Sign-ins
  People
  Groups
  Channels
  Sign-In            (an admin's)
  Workspace Providers
  Clients
  Overview
```

The Remote's Settings sheet: three sections with the same headings, This app / Machines /
Control plane, a row per page. The web page: three headings, **This browser** / **Machines** /
**Control plane**, each over its sections.

With no control plane paired, the Mac's Control plane group shows Account only.

## Decided

- Decided: **This app / Machines / Control plane**, because they are the three subjects Alex
  named, and "This app" cannot be read as this Mac the machine. The web says **This
  browser**. Alex can overrule.
- Decided: Account and Sign-ins go first under Control plane, because the person's record is
  kept there. Alex can overrule.
- Decided: project settings stay in the project's own sheet (FR-022's fourth scope), as now.
- Decided: in two steps. This change moves the panes. The next one puts the "same on every
  machine" switch at the top of Agent Runtimes, Agent Configuration, Cost and Resources, and
  removes On Every Machine (#2069). Alex can overrule.

## Step 2: the switch in each pane

On Every Machine is gone (#2069: people could not tell what follows them from a pane of its
own). Its parts go where the person changes them.

### The Mac

Agent Runtimes, Agent Configuration, Cost and Resources each start with a scope line: where
an edit in the pane goes, and the switch that changes it. Agent Configuration's Connectors
page has the MCP servers' line; its other pages have the agent configuration's.

```
┌ Agent Runtimes ──────────────────────────────────────────────┐
│ ⟳ All your machines          The same on all your machines ●│
│   Agent runtime choices: a change here goes to every machine │
│   of yours, and to each new one.                             │
├──────────────────────────────────────────────────────────────┤
│ (the pane, as before)                                        │

┌ Cost ────────────────────────────────────────────────────────┐
│ ▭ This Mac only              The same on all your machines ○│
│   Cost limits: turn it on to give every machine of yours     │
│   what this Mac has.                                         │
├──────────────────────────────────────────────────────────────┤
│ (the pane, as before)                                        │
```

To turn it off asks first: "Cost limits: each machine its own?" (Each Machine Its Own /
Cancel). Each machine keeps what it has then. The line is not there with no control plane
(there is one machine), or with no host on this Mac (nothing to take from).

**Machines ▸ Secrets** is a pane of its own: the secrets section of On Every Machine, as
it was.

### The Remote and the web page

Neither has an Agent Runtimes, Agent Configuration, Cost or Resources pane, and neither can
read a machine's files to take them. Their Machines page ends with the parts, and Secrets is
a row of its own:

```
Settings (Remote)                 Machines (Remote, its page)
  This app                          Versions …
    Appearance                      Git access …
    Notifications                   Backups …
    Sidebar                         The same on all your machines
  Machines                            Agent runtime choices
    Machines                ──▶         All your machines   [Each Machine Its Own]
    Secrets                           Cost limits
  Control plane                         Each machine its own
    …                                 …
                                      Turn one on in its own pane on the Mac.
```

The web page's Machines group: Git access, Machines, Backups, Servers' backups, **The same
on all your machines**, **Secrets**.

### Decided

- Decided: the switch is at the top of each Mac pane, with "All your machines" or "This Mac
  only", because #2069 found people cannot tell what follows them from a pane of its own.
  Alex can overrule.
- Decided: Secrets is a pane of its own under Machines on all three clients, because a
  secret goes to every machine of the person's and is used there (in an MCP server's env),
  and it has no other pane to go in. Alex can overrule.
- Decided: the MCP servers part (Connectors) goes at the top of Agent Configuration ▸
  Connectors on the Mac, because that is where its servers are changed. Alex can overrule.
- Decided: on the Remote and the web page, the parts go at the end of Machines, each with
  its state and Each Machine Its Own, because those clients have no pane for each part and
  cannot take a part from a machine; turning one on stays on the Mac. Alex can overrule.
- Decided: Use This Mac's on a part that is already the same everywhere goes, because the
  Mac then has every machine's copy, and an edit in the pane goes to all of them. Alex can
  overrule.
