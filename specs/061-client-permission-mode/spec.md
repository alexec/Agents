# Feature Specification: Client permission mode

**Feature Branch**: `061-client-permission-mode`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "Client-side permission mode global setting for Cursor only. This is an option in the settings with suitable permission mode (at least default, and auto-review)." Expanded to Grok, which also has no permission mode in the app. After shipping Auto-review, its classifier still interrupted ordinary turns, so the second choice became **Always-approve**: every permission request that offers allow-once is answered for you. Saved `autoReview` values migrate to Always-approve on load.

## Why this feature exists

Cursor and Grok both act without offering a permission mode under the prompt. Cursor's choices there are Agent, Plan and Ask, and none of them says how permission is answered. Grok shows no permission mode at all. Codex, by contrast, already offers **Ask for approval**, **Approve for me** and **Full access** on each agent.

When Cursor wants to edit, run a command, or use a tool, it shows a card above the prompt and the agent sits under **Needs you** until the person answers, on the Mac or on the phone. Grok can ask in the same way, and it can also be told, outside the app, to approve everything. The app starts Grok with no mode of its own, so an agent in the app follows whatever Grok was last told elsewhere.

The person wants one setting per runtime, for these two only, in Settings. **Default** asks before an action that needs permission. **Always-approve** answers every permission request from that runtime for you.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Permission requests proceed under Always-approve (Priority: P1)

The person is tired of approving every edit, test run and tool call. They open Settings, set Cursor or Grok to **Always-approve**, and the next agent on that runtime acts without a card and without moving to **Needs you**. The work still shows in the conversation. The other runtime is unchanged until its own control is switched.

**Why this priority**: This is the reason for the setting. Without it, these agents stay a sequence of permission cards, or, for Grok, whatever mode was saved outside the app.

**Independent Test**: Set Cursor to **Always-approve** and leave Grok on **Default**. Ask a Cursor agent to edit a file in the project, run the project's tests, and edit a file outside the project. All three happen with no permission card, no notification, and no **Needs you**. Ask a Grok agent to edit a file in the project. That edit waits. Then set Grok to **Always-approve** and ask again. That edit proceeds, and it is visible in the conversation.

**Acceptance Scenarios**:

1. **Given** a runtime's permission mode is **Always-approve**, **When** an agent on that runtime asks permission and the request offers **allow once** (or only **allow always**), **Then** the action proceeds at once, the agent does not show **Needs you**, and no notification is sent.
2. **Given** the same setting, **When** the agent asks to create, edit or delete a file inside or outside its project folder, **Then** the action proceeds at once and appears in the conversation as an approved action does today.
3. **Given** the same setting, **When** the agent asks to build, test, publish (`git push`), run with extra privilege, start another agent, change a workflow, or take the screen, a simulator or a browser, **Then** the request proceeds at once if it offers allow-once (or only allow-always).
4. **Given** the agent was moved into a worktree or given extra folders, **When** it asks permission, **Then** the setting still applies the same way; reach does not change Always-approve.
5. **Given** Cursor is **Always-approve** and Grok is **Default**, **When** each is asked to edit a file in its project, **Then** Cursor proceeds and Grok waits. The two controls do not move together.
6. **Given** **Always-approve**, **When** the app answers for the person, **Then** it prefers **allow once** so switching back to **Default** still asks for the same kind of action. It MUST NOT create a "don't ask again" grant of its own.

---

### User Story 2 - Default still asks, and it is where each setting starts (Priority: P1)

Someone who never opens the setting is asked before an edit. Someone who tries **Always-approve** and switches back gets the cards again, including for an agent that is already working. For Grok, **Default** asks even when Grok's own saved mode would have approved the action.

**Why this priority**: A permission setting that changes behaviour before anyone opts in would surprise every existing chat. Grok also has to stop inheriting a mode that was saved outside the app, or the control would do nothing on a machine where that mode approves everything.

**Independent Test**: On a fresh install, ask a Cursor agent and a Grok agent each to edit a file in the project. Each shows a permission card and waits under **Needs you**. Switch one runtime to **Always-approve**, then back to **Default**, and ask for another edit on that runtime. That edit waits again.

**Acceptance Scenarios**:

1. **Given** the person has never changed a runtime's setting, **When** they look at it, **Then** it is **Default**.
2. **Given** Cursor is **Default**, **When** a Cursor agent asks permission, **Then** the card appears as it does today, with the same buttons, and the agent waits under **Needs you** until it is answered, on the Mac or on the phone.
3. **Given** Grok is **Default**, **When** a Grok agent asks to edit a file or run a command that is not read-only, **Then** a permission card appears and the agent waits under **Needs you**. A read-only action Grok already runs without asking still does, and no card appears for it.
4. **Given** Grok's own settings, outside the app, say to approve every action, **When** the app's Grok control is **Default**, **Then** an agent the app starts still asks, as in scenario 3. Grok started in a terminal is left as it was.
5. **Given** an agent is mid-conversation under **Always-approve**, **When** the person switches that runtime's setting to **Default**, **Then** the next permission request shows a card and waits. A card already on screen stays until they answer it.
6. **Given** the person previously chose **Yes, and don't ask again** for a particular action, **When** the setting is **Default**, **Then** that earlier choice still applies. Actions **Always-approve** allowed on its own are not remembered as "don't ask again", so they wait again under **Default**.
7. **Given** a saved setting still named `autoReview` from an earlier build, **When** the daemon loads it, **Then** that runtime is **Always-approve**.

---

### User Story 3 - Questions still wait under Always-approve (Priority: P2)

**Always-approve** answers permission to act. It does not answer a question in words or a form with choices, and it does not invent an answer when the request offers no allow option.

**Why this priority**: A blanket yes on permission is only usable if questions still reach the person.

**Independent Test**: With **Always-approve** on for both, ask a Cursor agent a mid-turn question with choices, and ask a Grok agent a question in words. Cursor's question card waits. Grok ends the turn under **Waiting on your answer**. Neither is auto-answered.

**Acceptance Scenarios**:

1. **Given** **Always-approve**, **When** the agent asks a question that is not permission to act, **Then** the question is left for the person. Cursor's question card is shown as today. Grok's question still ends the turn, and the agent shows **Waiting on your answer**, as today.
2. **Given** **Always-approve**, **When** a permission request offers no allow-once and no allow-always option, **Then** the usual permission card appears and the agent waits.
3. **Given** a card from scenario 2, **When** the person is on the iPhone or iPad, **Then** the card and the notification arrive there the same way they do today.

---

### User Story 4 - One control each, found in Settings (Priority: P2)

Cursor and Grok each have one control, in one place, covering every agent that runtime starts on this Mac. Claude, Codex, Gemini, Antigravity and Copilot keep the permission modes they already have. The phone has no second copy of either control.

**Why this priority**: A per-chat capsule, or a setting that leaked onto Claude, would be a different feature. The person asked for a global option for the runtimes that do not already offer one.

**Independent Test**: Set both controls to **Always-approve**. Start a Cursor agent and a Grok agent from the prompt, one of them from a workflow, and a Claude agent. The Cursor and Grok agents proceed through a permission request with no card. The Claude agent still asks, exactly as it did before the feature existed. Neither prompt grows a permission-mode capsule.

**Acceptance Scenarios**:

1. **Given** the person opens **Settings ▸ Agent Runtimes**, **When** they look at the Cursor row and the Grok row, **Then** each has its own control, labelled as that runtime's permission mode, with **Default** and **Always-approve**, and the selected one is obvious. Each choice has a one-line description of what it allows.
2. **Given** one of those runtimes is not installed, **When** the person opens that pane, **Then** its control is still there and can be changed. It takes effect the next time an agent on that runtime asks.
3. **Given** a runtime's setting is **Always-approve**, **When** a workflow or another agent starts an agent on that runtime, **Then** the new agent follows that runtime's setting.
4. **Given** either setting is **Always-approve**, **When** a Claude, Codex, Gemini, Antigravity or Copilot agent asks permission, **Then** it asks exactly as it does today.
5. **Given** the person looks under a Cursor or Grok prompt, **When** either setting is either value, **Then** no permission-mode capsule appears there. Cursor's Agent, Plan and Ask are unchanged: Plan and Ask still cannot edit or run commands. The capsules Grok already shows stay as they are.
6. **Given** the person quits the app and opens it again, **When** they look at the two controls, **Then** each shows the value they last chose for it.
7. **Given** a project on a server, **When** a Cursor or Grok agent is started there from this Mac, **Then** it follows this Mac's setting for that runtime. The iPhone and iPad show no copy of either control.

---

### Edge Cases

- A permission card is already on screen when the setting changes. That card stays until the person answers it. The new value applies to the next request from an agent on that runtime.
- Two agents on the same runtime are working at once. Both follow that runtime's one setting, including an agent that started before the person changed it. The other runtime's agents follow theirs.
- **Always-approve** allows an action, and the person did not want it. They see it in the conversation and can switch that runtime's setting to **Default**. The feature does not add an undo for that action.
- Grok, under **Default**, runs a read or a read-only command that it already runs without asking. No card appears. The same action under **Always-approve** also proceeds.
- Switching only Cursor does not change a Grok agent that is already working, and the reverse.
- A tool this app refuses on its own (a conflicting runtime tool) is still refused under either setting; the person is not asked.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Settings MUST offer a permission mode for Cursor, on the Cursor row of **Settings ▸ Agent Runtimes**, and a permission mode for Grok, on the Grok row. Each has exactly two choices: **Default** and **Always-approve**. The two controls are independent.
- **FR-002**: Each choice MUST be a single value for the whole Mac. It MUST apply to every agent on that runtime which that Mac starts, in every project, including agents started by a workflow, agents started by another agent, agents already working, and agents whose project is on a server.
- **FR-003**: Until the person changes a control, its value MUST be **Default**.
- **FR-004**: Each choice MUST survive quitting and reopening the app. A stored value of `autoReview` MUST load as **Always-approve**.
- **FR-005**: Under **Default**, every permission request from an agent on that runtime MUST be shown and MUST wait for the person. Cursor's card and buttons stay as they are today. For Grok, an edit or a command that is not read-only waits on a card; a read-only action Grok already runs without asking still does. A mode saved in Grok's own settings MUST NOT change this for an agent the app starts.
- **FR-006**: Under **Always-approve**, the app MUST allow a permission request from that runtime without asking when the request offers an allow-once option, or only an allow-always option. It MUST prefer allow-once when both are offered.
- **FR-007**: Under **Always-approve**, the app MUST still show the usual permission card, and the agent MUST wait under **Needs you**, when the request offers no allow-once and no allow-always option.
- **FR-008**: Under **Always-approve**, a question that is not permission to act MUST still be left for the person. Cursor's question card stays as it is. Grok's question still ends the turn, and the agent shows **Waiting on your answer**.
- **FR-009**: An action allowed under **Always-approve** MUST appear in the conversation the same way an approved action does today. It MUST NOT put the agent under **Needs you** and MUST NOT send a notification.
- **FR-010**: Changing one runtime's setting MUST apply to the next permission request from an agent on that runtime. A card already on screen MUST stay until the person answers it. The other runtime's agents are unchanged.
- **FR-011**: An action the person has already marked "don't ask again" MUST stay allowed under either value. An action allowed only because of **Always-approve** MUST be asked again after that runtime's setting returns to **Default**.
- **FR-012**: The settings MUST NOT add a permission-mode control under the Cursor or Grok prompt, MUST NOT change Cursor's Agent, Plan or Ask, and MUST NOT change how Claude, Codex, Gemini, Antigravity or Copilot ask permission.
- **FR-013**: iPhone and iPad MUST NOT grow a copy of either control. Cards that still appear under **Default**, or under **Always-approve** when no allow option is offered, MUST arrive on the phone and iPad as they do today.
- **FR-014**: Each choice MUST show a one-line description: **Default** asks before that runtime does something that needs permission; **Always-approve** answers every permission request for you, while questions that are not permission still wait.

### Key Entities

- **Permission mode**: One saved choice per runtime, for Cursor and for Grok, either **Default** or **Always-approve**. Cursor's choice is independent of that agent's Agent, Plan or Ask mode. Grok's choice is independent of any permission mode saved in Grok's own settings. Neither choice is a permission mode of Claude, Codex, Gemini, Antigravity or Copilot.
- **Permission request**: The runtime asking before it acts. It names the action (the file, the command, or the tool). It is distinct from a question the person answers in words or by picking a choice.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person who has the app open can find either control and switch it in under 30 seconds, without starting an agent.
- **SC-002**: With that runtime's **Always-approve** on, a Cursor agent and a Grok agent each complete a file edit (inside or outside the project) and a test run with zero permission cards, zero notifications, and without entering **Needs you**. Both actions are visible in the conversation when the turn ends.
- **SC-003**: With **Always-approve** on, a mid-turn question that is not permission still waits for the person on each of the two runtimes, within the time a card or ended turn appears today.
- **SC-004**: With **Default**, or after switching back to **Default**, the next in-project edit on that runtime produces a permission card and waits. A fresh install starts both controls on **Default**. A Grok agent the app starts still waits on that edit when Grok's own settings would approve it.
- **SC-005**: After either setting is changed, a Claude agent and a Codex agent ask permission in the same cases they asked before the feature existed. No new permission-mode control appears under a Cursor or Grok prompt.
- **SC-006**: After quitting and reopening, each control shows the value the person last chose for it, and the next permission request on that runtime follows it. Changing Cursor's value does not change Grok's, or the reverse. A previously saved `autoReview` value reopens as **Always-approve**.
- **SC-007**: A card that still appears can be answered from the iPhone or iPad with the same steps as any other permission card.

## Docs *(mandatory)*

- `docs/reference/settings.md` — add: the Cursor and Grok permission mode controls on the **Agent Runtimes** pane, with **Default** and **Always-approve** and what each does.
- `docs/reference/runtimes.md` — change: the Cursor and Grok rows, so each still offers no permission mode under the prompt, and each says its permission mode lives in **Settings ▸ Agent Runtimes**.
- `docs/how-to/choose-runtime-model-mode.md` — add: Cursor's and Grok's permission modes are those settings, and the capsules under those prompts are unchanged.
- `docs/how-to/answer-a-question.md` — add: with **Always-approve**, every permission request from that runtime is answered for you; questions that are not permission still wait. Grok's questions in words are unchanged.

## Assumptions

- **Default** and **Always-approve** are the two choices, for each runtime. Always-approve is a blanket yes on permission requests that offer an allow option; it is not a smart review of reach or risk.
- The same rules (FR-006 and FR-007) decide **Always-approve** for Cursor and for Grok. Grok has its own modes outside the app; for agents the app starts, this setting is the one that applies under Default, and Always-approve answers for the person when Grok asks.
- Each control sits on that runtime's row in **Settings ▸ Agent Runtimes**, beside the other per-runtime controls, rather than on **Agents**, in a new pane, or as one shared switch for both.
- One value per runtime per Mac. It is not per project, per agent, or per workflow, and a workflow file cannot override it. It is not synced to another Mac. The phone and iPad follow the Mac they are paired with.
- Cursor's Agent, Plan and Ask stay as Cursor defines them. The setting only changes what happens when Cursor asks permission, which is while it is allowed to act.
- Grok in a terminal, and any permission mode saved in Grok's own settings, are unchanged. Only agents the app starts follow the app's Grok control.
- "Don't ask again" keeps its current meaning and is not rewritten by this feature. Automatic approvals prefer allow-once so Default still asks after a switch back.
- Read-only actions Grok already runs without a prompt stay that way under both values. **Default** does not invent new cards for them.
