# Implementation Plan: Our Tools, Not Theirs

**Branch**: `015-runtime-tool-scoping` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/015-runtime-tool-scoping/spec.md`

## Summary

One new table in `AgentsKitCore` — a `ToolPolicy` per runtime, saying which of that runtime's tools
an agent may keep — and three places that apply it: the command line a runtime is started with, the
environment it is started in, and the `_meta` object on `session/new`. Each of the three is a
mechanism rather than a runtime, so nothing downstream asks which runtime it is talking to; the
table is the only thing that knows.

Claude gets a denial list inside `_meta` and loses fifteen built-ins and two connectors. Copilot
gets three flags and loses its subagent and session-store tools, the built-in MCP servers, and the
whole rival `software-factory` server. Grok gets an agent profile inside `_meta` plus a generated
config overlay the app points `GROK_CONFIG_PATH` at, and loses its scheduler and subagent tools.
Cursor has no lever at all, so its three conflicting tools are residue.

Residue is covered twice: a line in the briefing, generated from the policy so the two cannot
disagree, and — where the runtime asks the client before running a tool — an automatic refusal from
the daemon, the mirror of the `autoAllowed` path that already answers permission questions about the
app's own tools. And because every one of these is a claim about somebody else's software, there is
a script beside `acp-handshake.sh` that re-asks every runtime what it has and reports anything the
policy does not account for.

Nothing is stored, no record grows a field, and nothing outside the daemon's own root is written.

## Technical Context

**Language/Version**: Swift 6, strict concurrency

**Primary Dependencies**: Foundation and the in-house `JSONRPCConnection`. No new dependency. The
check script is Python inside a zsh wrapper, exactly as `scripts/acp-handshake.sh` is.

**Storage**: One generated file, `<root>/runtimes/grok-overlay.toml`, written whole before a Grok
session starts and never read back by us. No change to `agent.json`, the transcript, or anything
else under the root.

**Testing**: `swift-testing` in `Packages/AgentsKit/Tests/AgentsKitTests`, split `Unit` /
`Integration` / `Live`. The Live suites are opt-in with `AGENTS_LIVE=1` and are where the claims
about other people's runtimes are held, following `GrokServedToolsTests`.

**Target Platform**: macOS app, `agentsd` daemon, shared `Packages/AgentsKit`. The remote is
untouched — an agent's tools are not something the phone draws.

**Project Type**: Desktop app plus a mobile remote over a local daemon.

**Performance Goals**: None. The policy is a static table; applying it is string concatenation at
launch and one object in a JSON-RPC call already being made.

**Constraints**:

- No code may branch on a runtime id beyond the policy table (README: "No code in the app asks which
  runtime it is talking to"). Levers are kinds of mechanism, not names of runtimes.
- Nothing belonging to the person may be written or read as configuration: not `~/.claude`, not
  `~/.copilot`, not `~/.grok`, not `~/.cursor`.
- The escalation tool must survive on every runtime that has one. It is the single thing this
  feature could break that would matter most.
- A stale tool name must never stop a session starting.
- Scoping must reach `session/new`, `session/load` and `session/fork`, or a picked-up agent is
  quietly wider than a new one.

**Scale/Scope**: Four policies, three lever kinds, one generated file, one briefing change, one
refusal path, one script. Around eight source files and six test suites.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unedited template — every principle is a
`[PRINCIPLE_N_NAME]` placeholder — so there are no ratified gates, and none are invented here. In
their place, the conventions this codebase holds itself to, read off the existing sources, and how
this design stands against each:

| Standing convention | How this design stands |
|---|---|
| No code asks which runtime it is talking to; a runtime that advertises a thing gets that thing (README, `RuntimeDiscovery`) | The four levers are mechanisms — deny list in `_meta`, allow list in `_meta`, launch flags, words. The runtime id appears once, as the key of the policy table. |
| A claim about somebody else's software gets a check that can be re-run (`scripts/acp-handshake.sh`, `GrokServedToolsTests`) | Every measurement in [research.md](./research.md) is reproducible, and `scripts/runtime-tools.sh` re-takes them on demand. |
| Mappings a person depends on are total and exhausted by a test (`AgentGroupTests`) | A unit test walks `RuntimeCatalog.builtIn` and fails on a runtime without a policy. A new runtime cannot arrive unscoped by accident. |
| An agent is told, in a sentence, what happened to anything it asked for (`AppService.Outcome`) | A residual tool's permission request is refused with the sentence from its remit category — the same sentence the briefing uses. |
| The briefing is paid for on the first prompt and stays short (`Briefing`) | This feature makes it shorter: where a tool is gone, the words about it go too. Residue lines are generated, so they exist only where they are earned. |
| Nothing is stored anywhere but the daemon's root, and the root is the daemon's identity (README, `StoreLocations`) | The one generated file lives under the root. A second daemon gets a second copy. Nothing goes near the person's home. |
| Refusals are plain sentences, not error codes (`WorkflowRefusal`) | The refusal names the app tool to use instead, rather than reporting that a tool was blocked. |

**Result**: pass. One row for Complexity Tracking — the app writes a config file for a runtime,
which it has never done before.

**Re-checked after Phase 1 design**: still passing, and one row got stronger. The "no code asks
which runtime" rule survived the awkward case: Grok needs an *allow* list where Claude needs a
*deny* list, which looks like a runtime-shaped fork. It is not — `sessionMetaAllowList` carries its
own `keep`, because "everything except these" and "only these" are different claims and the policy
is where a claim belongs. The rule that bent is the briefing's: it becomes `Briefing.text(for:)`,
which is a per-runtime string where there used to be one. Earned, because the residue differs per
runtime and a line naming a tool an agent does not have is worse than no line.

## Project Structure

### Documentation (this feature)

```text
specs/015-runtime-tool-scoping/
├── plan.md              # This file
├── research.md          # Phase 0 output — every lever, measured
├── data-model.md        # Phase 1 output — the policy shapes and the table itself
├── quickstart.md        # Phase 1 output — five checks
├── contracts/
│   ├── runtime-launch.md  # The wire: flags, environment, `_meta`, per runtime
│   ├── agent-facing.md    # What the agent is told: the briefing, the refusal
│   └── tool-check.md      # The re-check script and what is asserted automatically
├── checklists/
│   └── requirements.md  # Written by /speckit-specify; all items pass
└── tasks.md             # Written by /speckit-tasks — NOT created here
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
└── Runtimes/
    ├── ToolPolicy.swift            # NEW — RemitCategory, ToolPolicy, RemovedTool,
    │                               #       KeptTool, ResidualTool, Lever, EnvironmentFile
    ├── ToolPolicyCatalog.swift     # NEW — the four policies; total over RuntimeCatalog
    └── RuntimeCatalog.swift        # unchanged

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/
│   ├── ACPSession.swift            # + meta: JSONValue? on newSession / continueSession /
│   │                               #   forkSession; merged in sessionParams
│   └── Serve/Briefing.swift        # text → text(for:); workflows line shrinks;
│                                   #   residue line generated from the policy
├── Daemon/
│   ├── DaemonCore.swift            # ProcessSessionLauncher takes locations + policy;
│   │                               #   autoRefused(_:) beside autoAllowed(_:)
│   └── DaemonCore+Commands.swift   # passes policy.sessionMeta at freshSession and pick-up;
│                                   #   briefing by runtime
└── Runtimes/
    └── RuntimePolicyFiles.swift    # NEW — writes <root>/runtimes/*.toml, returns the env

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/ToolPolicyTests.swift      # NEW — totality, categories, the three wire shapes
├── Unit/BriefingTests.swift        # + residue lines, and their absence where there is none
├── Integration/ToolRefusalTests.swift  # NEW — a residual tool's permission question
└── Live/RuntimeToolScopingLiveTests.swift  # NEW — the four runtimes, for real

scripts/
└── runtime-tools.sh                # NEW — beside acp-handshake.sh
```

**Structure Decision**: the policy goes in `AgentsKitCore/Runtimes/`, beside `RuntimeCatalog` and
`Runtime`, because it is a description of a runtime and both halves may want to read it. Applying it
stays in `AgentsKit`: the launcher, the session and the daemon are the three that act. The remote is
not touched at all.

## Phased delivery

Each phase is a slice of the spec's user stories and leaves the app working.

| Phase | Stories | What lands |
|---|---|---|
| 1 | US1 | `ToolPolicy`, the catalog, `_meta` through `sessionParams`, Claude and Grok scoped. The schedule lands in the app on two runtimes. |
| 2 | US1, US2, US3, US4 | `ProcessSessionLauncher` takes the launch arguments and the generated overlay. Copilot scoped: its rival server, its subagents, its session store. Grok's overlay. |
| 3 | US1, US2 | `Briefing.text(for:)`, the residue lines, the shrunken workflows paragraph, and `autoRefused`. Cursor and Grok's residue covered. |
| 4 | US5 | `scripts/runtime-tools.sh`, the live suite, and the residue written down. |

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| The app generates a config file for a runtime (`<root>/runtimes/grok-overlay.toml`) — it has never written anything but its own records before | Grok reads feature switches only from a config file on disk, and it is the only way to turn its media tools off for our sessions | Inline `GROK_CONFIG` with the same TOML was measured and ignored (R6); editing `~/.grok/config.toml` is the person's file and is forbidden by FR-011; a temp file deleted per session risks vanishing under a process that may re-read it |
