# Feature Specification: Control runtime sandboxes

**Feature Branch**: `main` (no branch hook configured)

**Created**: 2026-09-28

**Status**: Draft

**Input**: User description: “Codex starts work trying to use a sandbox. That can fail. Audit which runtime have sandboxes and find out if they can be disabled.” Follow-up: “/$speckit-specify including wireframes.”

## Why this feature exists

An agent can stop before useful work begins because its runtime cannot start a command sandbox. The person needs to know whether the selected runtime will sandbox commands, choose a supported alternative, and understand what access that choice changes. A runtime's permission mode and its command sandbox are separate controls for most runtimes. The app's own folder and tool permissions remain separate as well.

The audit found documented sandbox-off routes for Codex, Claude, Gemini, Grok, Copilot and Cursor. Codex already offers **Full access**, which removes its sandbox and approval prompts together. Google documents Antigravity sandbox controls (`enableTerminalSandbox`, `--sandbox`) for its CLI and IDE, but Agents runs the separate `agy_acp_server` 1.2.1 binary. Neither the ACP registry entry for 1.2.1 nor Agents' pinned manifest lists a sandbox setting, and Agents passes no arguments on macOS (`--uid=` on Linux). The 049 research tested commands and permissions but not sandboxing, and its `AGY_ACP_DISABLE_WORKSPACE_TRUST=1` disables workspace trust, not a command sandbox. The server is proprietary, so the absence of a documented switch does not prove there is none. Antigravity's sandbox status in this integration is therefore unverified, and Agents must verify it before offering an Off choice.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Recover when a sandbox cannot start (Priority: P1)

When a sandbox fails at startup, the person sees the runtime, the reason, and a usable recovery action. If this runtime supports running without its sandbox, they can continue the original task without retyping it.

**Why this priority**: A startup failure stops all work on the task.

**Independent Test**: Cause a supported runtime's sandbox setup to fail before the first command. Confirm the error and recovery action appear. Take the action and confirm that the original task resumes. An ordinary command error must not offer this action.

**Acceptance Scenarios**:

1. **Given** sandbox setup fails, **when** the failure appears, **then** the conversation names the runtime, identifies sandbox setup as the cause, and preserves the task.
2. **Given** an Off choice is confirmed for the runtime and host, **when** sandbox setup fails, **then** the person can choose to continue without that runtime sandbox after seeing the access change.
3. **Given** no confirmed Off choice, **when** sandbox setup fails, **then** the error appears without a misleading recovery action.
4. **Given** a command is denied inside a working sandbox, **when** it fails, **then** it remains a command failure and no startup recovery appears.
5. **Given** a sandbox startup failure, **when** the person takes no action, **then** the agent stays stopped. It retries without its sandbox only after the person chooses that action.

---

### User Story 2 - Choose sandbox behavior before an agent starts (Priority: P1)

The person sees whether the chosen runtime will isolate commands and can select a supported alternative before work starts. The choice identifies any effect on approval prompts.

**Why this priority**: It avoids repeated failures on a host where a runtime sandbox cannot run.

**Independent Test**: Turn the sandbox off for a supported runtime, start an agent, and confirm it begins without a runtime sandbox attempt. Check that another runtime is unaffected and that the selected state appears in the conversation.

**Acceptance Scenarios**:

1. **Given** a runtime and host with confirmed On and Off choices, **when** the person views the runtime, **then** **As configured by runtime**, **On** and **Off** are explained. The first is selected until the person changes it.
2. **Given** Off is selected, **when** a new agent starts, **then** the runtime does not attempt to create its command sandbox and the conversation shows the effective choice.
3. **Given** the person has never chosen a new sandbox setting, **when** an agent starts, **then** it follows that runtime's existing Agents behavior.
4. **Given** Codex **Full access** is offered as an Off route, **when** the person views it, **then** the app says that it removes Codex approval prompts too.
5. **Given** one runtime's setting changes, **when** an agent on another runtime starts, **then** the other runtime's sandbox behavior is unchanged.
6. **Given** a user selects Off as one runtime's default, **when** another agent on that runtime starts without an override, **then** it starts with Off, including agents started by a workflow or another agent.
7. **Given** one agent overrides its runtime's default, **when** that agent starts or resumes, **then** it keeps its own choice and other agents continue to inherit the runtime default.
8. **Given** a per-agent override is cleared, **when** the agent next starts work, **then** it inherits the current runtime default.
9. **Given** Codex's runtime default is Off, **when** a new Codex agent has no override, **then** it starts in **Full access**. Choosing another Codex mode for that agent creates an agent-specific sandbox choice that agrees with the mode.

---

### User Story 3 - See what protection remains (Priority: P2)

The person can distinguish command sandboxing from the runtime's approvals and from Agents' folder and tool permissions. They can see the effective state on Mac and phone, including after a failure.

**Why this priority**: A bare “sandbox off” label would hide the practical access change.

**Independent Test**: Show a user the sandbox control and conversation state. Ask them to identify what Off changes, whether approval prompts remain, and which scope rules still apply. Compare their answers with an agent's actual behavior.

**Acceptance Scenarios**:

1. **Given** the sandbox control, **when** the person reads it, **then** its explanation separates command isolation from permission prompts.
2. **Given** the runtime sandbox is off, **when** the person views that agent on Mac or phone, **then** the effective state is visible before its first command.
3. **Given** the runtime sandbox is off, **when** an agent reaches outside an app-allowed folder or invokes an app-controlled tool, **then** Agents' existing scope and approval rules still apply.
4. **Given** vendor policy requires sandboxing, **when** the person views Off, **then** it is unavailable with a reason, and the app never claims it took effect.

### Edge Cases

- The runtime updates and no longer accepts the saved sandbox choice: show **Unavailable** and do not silently start with broader access.
- A sandbox fails after some commands completed: show the failure without repeating completed actions unbeknownst to the person.
- A setting changes while an agent is working: a command in progress keeps its current isolation; the UI says when the change takes effect.
- A workflow or helper starts an agent while nobody is watching: it follows the same effective policy and records a sandbox startup failure in that agent's conversation.
- A server supports a different sandbox mechanism from the Mac: determine availability where the agent runs.
- Gemini or another runtime has more than one sandbox layer: describe exactly which layers the choice affects.
- A failure comes from authentication, an approval refusal, or Agents' folder scope: do not call it a sandbox startup failure.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: For each runtime on the selected host, Agents MUST state whether its command sandbox is On, Off, Runtime controlled, or Unavailable for agents it starts.
- **FR-002**: Agents MUST offer an actionable Off choice only for runtime and host combinations where it can confirm that the exact integration honors the choice.
- **FR-003**: A new installation of this feature MUST preserve each runtime's effective sandbox behavior until the person deliberately changes it.
- **FR-003a**: Each runtime MUST have one saved sandbox default, and each agent MAY override that default. An agent without an override MUST inherit the runtime's current default, including an agent started by a workflow or another agent.
- **FR-003b**: The app MUST distinguish **Use runtime default** from an explicit **On** or **Off** override, and MUST let the person clear an override.
- **FR-003c**: Each runtime default MUST initially be **As configured by runtime**, which leaves the runtime's existing configuration in effect. If the app cannot determine the actual isolation under this choice, it MUST label the effective state **Runtime controlled** rather than claiming On or Off.
- **FR-004**: Agents MUST show sandbox state separately from permission mode and MUST explain any runtime that couples the two.
- **FR-005**: For Codex, Agents MUST explain that its existing **Full access** mode removes the sandbox and approval prompts together.
- **FR-005a**: Codex's sandbox state MUST agree with its selected mode. Choosing sandbox Off for Codex MUST select **Full access**; choosing a different Codex mode MUST update the displayed sandbox state. No screen may simultaneously show **Full access** and sandbox On.
- **FR-005b**: Choosing sandbox On while Codex is in **Full access** MUST select **Ask for approval** and tell the person that Codex approval prompts are restored.
- **FR-005c**: Codex agents that inherit a runtime default of Off MUST start in **Full access**. A person changing one Codex agent's mode MUST create or update that agent's override so the selected mode and displayed sandbox state agree without changing the runtime default.
- **FR-006**: Agents MUST distinguish sandbox startup failure from command denial inside a sandbox, ordinary command failure, permission refusal and authentication failure.
- **FR-007**: After a sandbox startup failure, Agents MUST preserve the task and offer a supported recovery action when one exists, explaining the access change before work resumes.
- **FR-007a**: Agents MUST stop after a sandbox startup failure and MUST NOT retry without a sandbox until the person selects that recovery action. The recovery choice MUST change only the affected agent's override.
- **FR-008**: Agents MUST NOT claim Off took effect if the runtime rejects it, a vendor policy forbids it, or that runtime version does not support it.
- **FR-009**: Switching off a runtime sandbox MUST NOT alter Agents' folder scope, tool permissions or approval decisions.
- **FR-010**: The effective sandbox state MUST be visible in an agent's conversation on Mac, iPhone and iPad before its first command and after recovery.
- **FR-011**: The runtime default MUST apply consistently to manually started agents, workflow agents and agents started by another agent, on Mac and supported server hosts, except where that agent has an explicit override. A helper's sandbox MUST NOT be looser than that of the agent that started it (the existing helper looseness cap); a capped helper shows that reason in its effective state.
- **FR-012**: A changed runtime default or agent override MUST take effect at the agent's next turn. Agents MUST state this when a change is made mid-turn and MUST NOT change the isolation of a command in progress.
- **FR-013**: Antigravity's pinned `agy_acp_server` 1.2.1 MUST show its command sandbox as **Unavailable**, with the reason that its sandbox behavior is unverified for the ACP server, and MUST offer no actionable Off choice. CLI or IDE sandbox flags, CLI settings and `AGY_ACP_DISABLE_WORKSPACE_TRUST` MUST NOT be treated as an Off route. This holds until the exact server version's behavior is verified on the host or Google confirms a switch for that server.
- **FR-014**: Each choice MUST have a concise explanation of its command file and network limits and whether it changes approvals. Where a runtime's own configuration determines behavior, the app MUST state that it does not control the setting.

### Key Entities

- **Runtime sandbox capability**: The choices a particular runtime version supports on a particular host, including a policy restriction or an unverified integration.
- **Sandbox preference**: The person's requested command isolation choice and the agents to which it applies.
- **Runtime default**: The saved choice every agent on that runtime inherits unless it has its own override.
- **Agent override**: One agent's explicit choice, which persists with that agent and can be cleared to resume inheritance.
- **Effective sandbox state**: The isolation actually in force for one agent and the reason a preference could not be honored.
- **Sandbox startup failure**: A runtime-reported failure to establish command isolation, distinct from a command blocked after isolation started.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a usability review, 9 of 10 people find a selected runtime's sandbox state and correctly explain Off within 60 seconds.
- **SC-002**: Every actionable Off choice starts an agent without a runtime sandbox setup attempt in 100% of checked runtime-host combinations.
- **SC-003**: In 100% of induced, identifiable sandbox startup failures, the conversation names the cause and does not silently continue with broader access.
- **SC-004**: In 100% of induced ordinary command denials, no sandbox startup recovery is offered.
- **SC-005**: A person recovers from a supported sandbox startup failure and continues the original task in at most three actions without retyping the prompt.
- **SC-006**: Every runtime retains its prior effective sandbox behavior on first start after the feature is installed.
- **SC-007**: Existing Agents folder and tool restrictions still refuse every previously out-of-scope action in a representative check with runtime sandbox Off.
- **SC-008**: Changing a runtime default changes 100% of subsequent starts by inheriting agents on that runtime and 0% of agents with an explicit override.
- **SC-009**: In 100% of induced sandbox startup failures, no unsandboxed retry occurs before a person explicitly chooses it.

## Docs *(mandatory)*

- `docs/how-to/choose-runtime-model-mode.md` — explain how to see and choose sandbox state and how it differs from runtime mode.
- `docs/reference/runtimes.md` — list verified controls and unavailable runtime-host combinations.
- `docs/reference/settings.md` — describe each runtime sandbox setting, its reach and when changes apply.
- `docs/how-to/answer-a-question.md` — explain sandbox startup recovery and its access change.

## Wireframes

The settings, agent start and failure flows are in [wireframe.md](wireframe.md), including the state on iPhone.

## Assumptions

- The requested feature concerns the seven command runtimes Agents supports, prompted by Codex sandbox startup failures. It does not change macOS App Sandbox or Agents' own folder scope.
- Existing runtime behavior is preserved until the person explicitly changes a choice.
- Vendor-managed restrictions take precedence over a person's preference and are shown as unavailable.
- A vendor CLI switch is evidence of product capability, but the exact ACP integration and version must be checked before Agents offers it.
- As of 2026-09-28, Antigravity `agy_acp_server` 1.2.1 has no documented or tested sandbox switch; a new pinned version needs the same check before its status changes.
