# Layouts: Write It for Me (L10)

This continues #691's [layouts](../../691-workspace-providers/contracts/layouts.md). It changes
L4 (Add Provider), on the Mac only.

**Settled by Alex, 2026-10-12**: Write It for Me is a button in the form. The sheet shows the
agent's steps, then the draft in the form's own fields with the list it got. Add accepts it.
The Remote and the web page get nothing: there is no Providers page on them (L7).

## L10a. MCP server, before

```text
┌ Add MCP server ───────────────────────────────────────┐
│ Name     [DigitalOcean                  ]             │
│ Server   (•) A command  ( ) An address                │
│ Command  [npx -y @digitalocean/mcp      ]             │
│ Secrets  DIGITALOCEAN_API_TOKEN [••••••••]  [+]       │
│                                                       │
│ Tool map               [Claude ▾] [Write It for Me]   │
│ ┌───────────────────────────────────────────────────┐ │
│ │                                                   │ │
│ └───────────────────────────────────────────────────┘ │
│ Leave it empty for a server that follows the contract.│
│                                        [Back] [Add]   │
└───────────────────────────────────────────────────────┘
```

- The runtime menu lists only runtimes that can run as a writer (research R2). It is hidden
  when there is only one.
- Write It for Me is off until there is a command or an address.

## L10b. While it writes

```text
│ Tool map                                              │
│ ◌ Writing… read 41 tools · checked: listed 3   $0.02 ×│
│ ┌───────────────────────────────────────────────────┐ │
│ │ (read-only while it writes)                       │ │
│ └───────────────────────────────────────────────────┘ │
│                                 Details…              │
│                                        [Back] [Add]   │  Add is off
```

**Details…** is a popover with every step and a link to the read-only transcript:

```text
┌ Writing a tool map · Claude ─────────────────────────┐
│ 14:31:02  read 41 tools                              │
│ 14:31:20  check failed: list.items finds no list     │
│ 14:31:41  checked: listed 3                          │
│ 14:31:44  sent the draft                             │
│                                   [Open Transcript]  │
└──────────────────────────────────────────────────────┘
```

## L10c. A question (start, stop, or a check it may not run alone)

```text
│ ┌───────────────────────────────────────────────────┐ │
│ │ Claude wants to start scratch-1 on DigitalOcean   │ │
│ │ to prove the map. $0.03/h while running.          │ │
│ │ It stays running until you stop it.               │ │
│ │                            [Don't] [Start It]     │ │
│ └───────────────────────────────────────────────────┘ │
```

- The question is in the sheet, under the step line, with an accent bar (the #776 card style).
- For a check: "Claude wants to run `cws list --all` to check the config. It isn't on the safe
  list because ‹reason›." with [Don't] [Run Check].
- No answer in 2 minutes is Don't.

## L10d. Done

```text
│ Tool map                    [Claude ▾] [Write Again]  │
│ ┌───────────────────────────────────────────────────┐ │
│ │ {                                                 │ │
│ │   "list": { "tool": "droplet-list", …             │ │
│ │ }                                                 │ │
│ └───────────────────────────────────────────────────┘ │
│ ✓ Listed 3: agents-devbox (running), build-box        │
│   (stopped), scratch-1 (stopped)                      │
│ Written by Claude. Read it before you add it.         │
│ "start and stop are droplet-actions-power-on/off;     │
│  I didn't try them."                       Details…   │
│                                        [Back] [Add]   │
```

- The quote is the agent's note from `send_draft`, at most three lines.
- The field is editable. A change drops "Written by" and keeps the list line, marked
  "(before your change)".

## L10e. Your commands

```text
┌ Add Your commands ────────────────────────────────────┐
│ Name     [Company workspaces           ]              │
│ CLI      [cws                          ]              │
│                        [Claude ▾] [Write It for Me]   │
│ ── or by hand ──                                      │
│ Workspace [devstack-1    ]  ssh [devstack-1.cws     ] │
│ Start     [cws start devstack-1                     ] │
│ Stop      [cws stop devstack-1                      ] │
│ Status    [cws status devstack-1                    ] │
│                                        [Back] [Add]   │
└───────────────────────────────────────────────────────┘
```

When the agent's config has `list` (many workspaces), the by-hand fields give way to a
**Config** editor that holds the JSON, with the same lines as L10d under it.

## L10f. A refusal at Add, and Edit…

```text
│ ⚠ It isn't a workspace provider: it has no workspaces_list, │
│   workspace_start or workspace_stop tool.                   │
│                                        [Write a Tool Map]   │
```

The provider card's Edit… sheet has the same Write It for Me, starting from the old map, and
**Save** in place of Add (US4).

## Remote and web

None. The parity table's row for Workspace providers adds "Write It for Me (#858)" to its Mac
column. Remote and web stay "None", **by design**.
