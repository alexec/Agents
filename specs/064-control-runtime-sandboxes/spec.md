# Feature Specification: Control runtime sandboxes

**Feature Branch**: `agents/work-github-issue-40`

**Created**: 2026-09-28. **Revised**: 2026-09-29 (#40), after the research was redone under ACP.

**Status**: Draft

**Input**: User description: “Codex starts work trying to use a sandbox. That can fail. Audit which runtime have sandboxes and find out if they can be disabled.” Follow-up: “/$speckit-specify including wireframes.” Revision: issue #40, “Resurrect runtime sandbox controls (064) and re-check the research”.

## Why this feature exists

An agent can stop before useful work begins because its runtime cannot set up a command sandbox. The person needs to know whether the selected runtime will sandbox commands, choose a supported alternative, and understand what access that choice changes. A runtime's permission mode and its command sandbox are separate controls for most runtimes. The app's own folder and tool permissions remain separate as well.

The research was redone on 2026-09-29 by running every route under ACP, on the versions the app runs today, on the Mac and on a Linux server ([research.md](research.md), R9). It found:

- **Claude, Codex and Grok** can be told to sandbox commands or not, and each choice was shown to take effect.
- **Gemini** can be told not to sandbox. Its sandbox cannot run under the app at all: with it on, Gemini never starts.
- **Cursor** ignores the sandbox flag when it runs for the app; only its own settings decide.
- **Copilot**'s flags could not be proven, because its quota was spent. It is added once they are.
- **Antigravity** sandboxes commands only for a business account whose admin turns that on.
- **OpenCode** has no command sandbox.

A sandbox that fails shows up in three ways: the runtime refuses to start (Grok; Claude and Gemini on a server), a command fails and the turn carries on (Claude and Codex), or the runtime never answers (Gemini). Each was captured for real.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Recover when a sandbox cannot start (Priority: P1)

When a runtime's sandbox fails to set up, the person sees the runtime, the reason, and a usable recovery action. If this runtime can run without its sandbox, they can continue the original task without retyping it.

**Why this priority**: A sandbox that cannot start stops all work on the task, and today the only sign is a vague error or the agent's own words.

**Independent Test**: Cause a supported runtime's sandbox setup to fail. Confirm the card appears when the turn ends, or at once if the runtime would not start. Take the action and confirm that the original task resumes. An ordinary command denied inside a working sandbox must not offer this action.

**Acceptance Scenarios**:

1. **Given** sandbox setup fails, **when** the failure appears, **then** the conversation names the runtime, identifies sandbox setup as the cause, and preserves the task.
2. **Given** the runtime can run with its sandbox off, **when** sandbox setup fails, **then** the person can choose to continue without that runtime's sandbox after seeing the access change.
3. **Given** the runtime cannot be told to run without its sandbox, **when** sandbox setup fails, **then** the error appears with the reason and without a misleading recovery action.
4. **Given** a command is denied inside a working sandbox, **when** it fails, **then** it remains a command failure and no recovery appears.
5. **Given** a sandbox startup failure, **when** the person takes no action, **then** the agent stays stopped. It retries without its sandbox only after the person chooses that action.
6. **Given** a command's sandbox fails part way through a turn and the runtime carries on, **when** the turn ends, **then** the agent stops there with the card. The turn is not cut off.
7. **Given** Gemini never answers when started, **when** the app gives up waiting, **then** it says Gemini's sandbox probably could not start and offers to continue without it.

---

### User Story 2 - Choose sandbox behavior before an agent starts (Priority: P1)

The person sees whether the chosen runtime will sandbox commands and can select a supported alternative before work starts. The choice says whether it changes approval prompts.

**Why this priority**: It avoids repeated failures on a host where a runtime's sandbox cannot run.

**Independent Test**: Turn the sandbox off for Claude, start an agent, and confirm its commands reach outside the project. Check that another runtime is unaffected and that the choice appears in the conversation.

**Acceptance Scenarios**:

1. **Given** a runtime with choices, **when** the person views it in Settings, **then** each choice is explained, and **As configured by runtime** is selected until the person changes it.
2. **Given** Off is selected, **when** a new agent starts, **then** the runtime does not sandbox its commands and the conversation shows the effective choice.
3. **Given** the person has never chosen, **when** an agent starts, **then** it starts exactly as it does today.
4. **Given** Codex, **when** the person views Off, **then** the app says it is **Full access**, which removes Codex approval prompts too.
5. **Given** one runtime's setting changes, **when** an agent on another runtime starts, **then** the other runtime's sandbox behavior is unchanged.
6. **Given** a runtime default of Off, **when** another agent on that runtime starts without an override, **then** it starts with Off, including agents started by a workflow or another agent.
7. **Given** one agent overrides its runtime's default, **when** that agent starts or resumes, **then** it keeps its own choice and other agents continue to inherit the runtime default.
8. **Given** a per-agent override is cleared, **when** the agent next starts work, **then** it inherits the current runtime default.
9. **Given** Codex's runtime default is Off, **when** a new Codex agent has no override, **then** it starts in **Full access**. Choosing another Codex mode for that agent creates an agent-specific choice that agrees with the mode.

---

### User Story 3 - See what protection remains (Priority: P2)

The person can tell command sandboxing apart from the runtime's approvals and from the app's folder and tool permissions. They can see the effective state on Mac and phone, including after a failure, and why a runtime has no control.

**Why this priority**: A bare “sandbox off” label would hide the practical access change.

**Independent Test**: Show a person the sandbox control and conversation state. Ask them to identify what Off changes, whether approval prompts remain, and which scope rules still apply. Compare their answers with an agent's actual behavior.

**Acceptance Scenarios**:

1. **Given** the sandbox control, **when** the person reads it, **then** its explanation separates command isolation from permission prompts.
2. **Given** the runtime sandbox is off, **when** the person views that agent on Mac or phone, **then** the effective state is visible before its first command.
3. **Given** the runtime sandbox is off, **when** an agent reaches outside an app-allowed folder or invokes an app-controlled tool, **then** the app's existing scope and approval rules still apply.
4. **Given** Cursor, Copilot, Antigravity or OpenCode, **when** the person views it, **then** they see its state (**Runtime controlled** or **No sandbox**) and one sentence saying why the app offers no choice.

### Edge Cases

- A runtime updates and stops honouring a route: the next failure is recognised as usual, and the app never claims a state it cannot vouch for.
- A sandbox fails after some commands completed: the recovery continues the task rather than repeating the prompt, and the card says so first.
- A setting changes while an agent is working: a command in progress keeps its current isolation; the UI says the change applies from the next turn.
- A workflow or helper starts an agent while nobody is watching: it follows the same effective policy and records a sandbox failure in that agent's conversation.
- A server lacks what a sandbox needs (bubblewrap, Docker, user namespaces): the failure is recognised there and the same recovery is offered.
- Gemini's own settings turn its sandbox on: under **As configured by runtime** it never starts; that is recognised (US1-7).
- A failure comes from authentication, an approval refusal, a spent allowance or the app's folder scope: it is never called a sandbox failure.
- Grok's sandbox is fixed for the life of its process; the app starts a process per turn, so a change still applies from the next turn.

## Requirements *(mandatory)*

### Functional Requirements

**State and choices**

- **FR-001**: For each runtime, the app MUST state its command sandbox for agents it starts as one of **On**, **Off**, **Runtime controlled** or **No sandbox**.
- **FR-002**: The app MUST offer a choice only where its route was measured to take effect under ACP (research R9). Today: Claude, Codex and Grok (**On** and **Off**) and Gemini (**Off**). The catalog records the version each route was measured on.
- **FR-003**: Until the person changes a choice, every runtime MUST start exactly as it does today.
- **FR-003a**: Each runtime with choices MUST have one saved default, and each agent MAY override it. An agent without an override MUST inherit the runtime's current default, including an agent started by a workflow or another agent.
- **FR-003b**: The app MUST distinguish **Use runtime default** from an explicit **On** or **Off** override, and MUST let the person clear an override.
- **FR-003c**: Each runtime default MUST initially be **As configured by runtime**, which adds nothing to the launch. Where the app cannot know the resulting state, it MUST say **Runtime controlled** rather than claim On or Off.
- **FR-004**: The app MUST show the sandbox apart from the permission mode and MUST explain any runtime that couples the two.
- **FR-005**: For Codex, the app MUST explain that **Full access** removes the sandbox and approval prompts together.
- **FR-005a**: Codex's sandbox state MUST agree with its mode. Choosing Off MUST select **Full access**; choosing a different mode MUST update the displayed state. No screen may show **Full access** with the sandbox On.
- **FR-005b**: Choosing On while Codex is in **Full access** MUST select **Ask for approval** and say that approval prompts return.
- **FR-005c**: Codex agents inheriting a default of Off MUST start in **Full access**. Changing one agent's mode MUST update that agent's override, not the runtime default.
- **FR-013**: Antigravity MUST show **No sandbox**, saying that only a business account's admin can turn its sandbox on. Cursor and Copilot MUST show **Runtime controlled**, saying their own settings decide. OpenCode MUST show **No sandbox**.
- **FR-015**: Gemini MUST offer **As configured by runtime** and **Off** only, and say why On is not offered: its sandbox cannot start when the app runs it.
- **FR-014**: Each choice MUST have a concise explanation of what it limits (files, network) and whether it changes approvals. Where the runtime's own settings decide, the app MUST say it does not control them.

**Failure and recovery**

- **FR-006**: The app MUST distinguish a sandbox that failed to set up from a command denied inside a working sandbox, an ordinary command failure, a permission refusal, a spent allowance and an authentication failure.
- **FR-006a**: A runtime that refuses to start because of its sandbox MUST stop the agent at once with the card. A command whose sandbox failed part way through a turn MUST NOT cut the turn off; the agent stops with the card when that turn ends.
- **FR-006b**: A Gemini start that never answers MUST be recognised as its sandbox hanging.
- **FR-007**: After a sandbox failure, the app MUST preserve the task and offer **Continue without sandbox** when this runtime has an Off route, explaining the access change before work resumes.
- **FR-007a**: The app MUST NOT retry without a sandbox until the person chooses that action. The choice MUST change only the affected agent's override.
- **FR-008**: The app MUST NOT claim Off took effect where a vendor policy overrides it or the runtime has no measured route.
- **FR-009**: Switching off a runtime sandbox MUST NOT alter the app's folder scope, tool permissions or approval decisions.

**Reach**

- **FR-010**: The effective sandbox state MUST be visible in an agent's conversation on Mac, iPhone and iPad before its first command and after recovery.
- **FR-011**: The runtime default MUST apply consistently to manually started agents, workflow agents and agents started by another agent, on the Mac and on servers, except where that agent has an override. A helper's sandbox MUST NOT be looser than that of the agent that started it; a capped helper shows that reason.
- **FR-012**: A changed runtime default or agent override MUST take effect at the agent's next turn. The app MUST say so when a change is made mid-turn and MUST NOT change the isolation of a command in progress.
- **FR-016**: The app MUST NOT write any runtime's own settings files to apply a choice (as 067's FR-004).

### Key Entities

- **Sandbox route**: per runtime, how On and Off are expressed (an argument, an environment variable, a session option, a mode, or none), the version it was measured on, and the sentence shown where there is no route.
- **Runtime default**: the saved choice every agent on that runtime inherits unless it has its own override.
- **Agent override**: one agent's explicit choice, kept with the agent, which can be cleared.
- **Effective sandbox state**: the isolation in force for one agent at its latest turn, and the reason a preference could not be honoured.
- **Sandbox failure**: a runtime's report that it could not set up command isolation, distinct from a command blocked after isolation started.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a usability review, 9 of 10 people find a selected runtime's sandbox state and correctly explain Off within 60 seconds.
- **SC-002**: Every offered Off choice starts an agent whose commands reach outside the project, in 100% of checked runtime and host combinations.
- **SC-003**: In 100% of induced sandbox failures of the kinds in the fixtures, the conversation names the cause and does not silently continue with broader access.
- **SC-004**: In 100% of induced ordinary command denials, no recovery is offered.
- **SC-005**: A person recovers from a sandbox failure and continues the original task in at most three actions without retyping the prompt.
- **SC-006**: Every runtime starts with exactly what it started with before this feature, until a choice is changed.
- **SC-007**: The app's folder and tool restrictions still refuse every previously out-of-scope action with the runtime sandbox Off.
- **SC-008**: Changing a runtime default changes 100% of subsequent starts by inheriting agents on that runtime and 0% of agents with an override.
- **SC-009**: In 100% of induced sandbox failures, no unsandboxed retry happens before a person chooses it.

## Docs *(mandatory)*

- `docs/how-to/choose-runtime-model-mode.md` — how to see and choose the sandbox, and how it differs from the mode.
- `docs/reference/runtimes.md` — the sandbox row of each runtime's options table: what the app sets, and why a runtime has no choice.
- `docs/reference/settings.md` — the **Command sandbox** setting on each runtime's page, its reach and when a change applies.
- `docs/how-to/answer-a-question.md` — the **Sandbox could not start** card and its access change.

## Wireframes

The settings, new chat, prompt bar and failure card are in [wireframe.md](wireframe.md), including the phone.

## Assumptions

- The feature covers the eight runtimes the app supports. It does not change macOS App Sandbox or the app's own folder scope.
- Existing behavior is preserved until the person explicitly changes a choice.
- Vendor-managed restrictions (Claude's managed settings, Copilot's policy, Antigravity's admin controls) take precedence over a person's choice.
- The routes are those measured on 2026-09-29; `scripts/sandbox-probe.sh` re-measures them when a runtime changes. There is no probe inside the app (Alex, 2026-09-29).
- Copilot's `--no-sandbox` and `--sandbox` are added in a follow-up once measured.
- Web access, usage data and memory are 067's switches, on the same Settings page; the sandbox's own network limits are part of this feature only as far as each runtime's sandbox includes them.
