# Runtime sandbox controls — wireframes

These show the control and wording, not a new destination. A runtime default lives on its existing page in **Settings ▸ Agent Runtimes**. One agent's override lives with that agent's existing mode and model controls. The effective state is visible in the conversation on Mac and phone.

## Mac: runtime default

Example: Grok, whose sandbox can be disabled independently of permission mode.

```text
┌──────────────────────────────────────────────────────────────┐
│ Settings                                        Agent Runtimes │
│ Claude                                                     ▸ │
│ Codex                                                      ▸ │
│ Grok                                                        │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ Installed                                                │ │
│ │ Permission mode                        [Default       ▾] │ │
│ │                                                          │ │
│ │ Command sandbox                                          │ │
│ │ Default                    [As configured by runtime ▾]  │ │
│ │   As configured by runtime                               │ │
│ │   On                                                     │ │
│ │   Off                                                    │ │
│ │ Limits what Grok commands can reach. Permission mode is │ │
│ │ a separate choice. New agents inherit this default.     │ │
│ └──────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

**As configured by runtime** is the initial value. It leaves the runtime's existing settings in effect. If Agents cannot read their effective sandbox state, it says **Runtime controlled** on agents that inherit this default; it does not claim they are On or Off. A change to the default affects the next turn of inheriting agents, including workflow and helper agents. Agents with explicit overrides retain their own choice.

## Mac: one agent's choice

```text
┌──────────────────────────────────────────────────────────────┐
│ New Codex agent                                              │
│                                                              │
│ [ Ask Codex to work on this project…                    ]    │
│                                                              │
│ Runtime [Codex ▾]    Mode [Ask for approval ▾]               │
│ Sandbox [Use runtime default ▾]                              │
│           Use runtime default                                │
│           On                                                 │
│           Off — Full access; approval prompts also off       │
│                                                              │
│ Effective: sandbox on · approval on request                  │
│                                               [Start agent]  │
└──────────────────────────────────────────────────────────────┘
```

For Codex, selecting **Off** also selects its existing **Full access** mode. Selecting **On** from **Full access** selects **Ask for approval** and says that approval prompts return. Changing Codex's mode updates the displayed sandbox state, so the two controls cannot disagree. The same **Use runtime default / On / Off** choice appears for a running agent; a change applies on its next turn, never in the middle of a command.

## Mac: sandbox cannot start

```text
┌──────────────────────────────────────────────────────────────┐
│ Codex · Needs you                                            │
│                                                              │
│ Sandbox could not start                                      │
│ Codex could not isolate commands on this host.              │
│ [Show error details]                                         │
│                                                              │
│ Continue without Codex's sandbox?                            │
│ This sets this agent to Full access. Codex approval prompts  │
│ will also be off. Agents' folder and tool rules still apply.│
│                                                              │
│          [Keep stopped]  [Continue without sandbox]          │
└──────────────────────────────────────────────────────────────┘
```

The recovery changes only this agent's override. It keeps the original prompt and conversation. **Keep stopped** or leaving the card unanswered never retries with broader access. If Off is unverified or blocked by vendor policy, the card shows the reason and omits **Continue without sandbox**. An ordinary command denial appears as its normal tool failure instead.

## iPhone and iPad: start and failure

```text
┌────────────────────────────────┐  ┌────────────────────────────────┐
│ Start agent                    │  │ Codex · Needs you             │
│                                │  │                                │
│ Runtime             Codex    ▸ │  │ Sandbox could not start       │
│ Mode      Ask for approval   ▸ │  │ Commands could not be         │
│ Sandbox  Use runtime default ▸ │  │ isolated on this host.        │
│ Model              Auto      ▸ │  │                                │
│                                │  │ Continue without sandbox      │
│ [ Start ]                      │  │ also turns Codex approvals off.│
│                                │  │                                │
│                                │  │ [Keep stopped]                 │
│                                │  │ [Continue without sandbox]     │
└────────────────────────────────┘  └────────────────────────────────┘
```

The phone exposes one agent's override in its existing start form and the same recovery decision as the Mac. It does not duplicate the runtime-wide Settings page. The conversation shows **Sandbox On**, **Sandbox Off**, or **Runtime controlled** beside the agent's other current choices.

## Unverified or restricted runtime

```text
┌──────────────────────────────────────────────────────────────┐
│ Antigravity                                                  │
│ Command sandbox                         Unavailable          │
│ Unverified for agy_acp_server 1.2.1, the ACP server Agents   │
│ uses. Google's CLI and IDE sandbox switches do not apply.    │
│ Existing Antigravity behavior stays in effect.               │
└──────────────────────────────────────────────────────────────┘
```

The app offers an actionable Off choice only after it is shown to work with the installed integration on that host. A managed policy that requires sandboxing produces a similar **Unavailable** explanation naming the policy rather than silently accepting Off.
