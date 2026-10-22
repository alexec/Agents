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
| **Machines** | the machines that run agents | Machines, Agent Runtimes, Agent Configuration, Cost, Resources, On Every Machine | Machines, On Every Machine | Git access, Machines, Backups, Servers' backups, On Every Machine |
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
  On Every Machine
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
