# Feature Specification: Client permission mode

**Feature Branch**: `061-client-permission-mode`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "Client-side permission mode global setting for Cursor only. This is an option in the settings with suitable permission mode (at least default, and auto-review)." Expanded to Grok, which also has no permission mode in the app.

## Why this feature exists

Cursor and Grok both act without offering a permission mode under the prompt. Cursor's choices there are Agent, Plan and Ask, and none of them says how permission is answered. Grok shows no permission mode at all. Codex, by contrast, already offers **Ask for approval**, **Approve for me** and **Full access** on each agent.

When Cursor wants to edit, run a command, or use a tool, it shows a card above the prompt and the agent sits under **Needs you** until the person answers, on the Mac or on the phone. Grok can ask in the same way, and it can also be told, outside the app, to approve everything. The app starts Grok with no mode of its own, so an agent in the app follows whatever Grok was last told elsewhere.

The person wants one setting per runtime, for these two only, in Settings. **Default** asks before an action that needs permission. **Auto-review** lets ordinary work inside the project proceed, and still asks when the action leaves the project, publishes, or needs extra privilege.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Ordinary work proceeds under Auto-review (Priority: P1)

The person is tired of approving every edit and every test run. They open Settings, set Cursor or Grok to **Auto-review**, and the next agent on that runtime edits a file in the project and runs its tests without a card and without moving to **Needs you**. The work still shows in the conversation. The other runtime is unchanged until its own control is switched.

**Why this priority**: This is the reason for the setting. Without it, these agents stay a sequence of permission cards, or, for Grok, whatever mode was saved outside the app.

**Independent Test**: Set Cursor to **Auto-review** and leave Grok on **Default**. Ask a Cursor agent to edit a file in the project and run the project's tests. Both happen with no permission card, no notification, and no **Needs you**. Ask a Grok agent to edit a file in the project. That edit waits. Then set Grok to **Auto-review** and ask again. That edit proceeds, and it is visible in the conversation.

**Acceptance Scenarios**:

1. **Given** a runtime's permission mode is **Auto-review**, **When** an agent on that runtime asks to create, edit or delete a file inside the folder it is working in, **Then** the action proceeds at once, the agent does not show **Needs you**, and no notification is sent.
2. **Given** the same setting, **When** the agent asks to build, test, format, or install packages whose files land in that folder, **Then** the command proceeds at once and its output appears in the conversation as it does today.
3. **Given** the same setting, **When** the agent asks to run local git that stays in that folder (`status`, `diff`, `log`, `add`, `commit`, `checkout`, `branch`, `fetch` or `pull`), **Then** the command proceeds at once.
4. **Given** the agent was given extra folders before it started (**Reach**), **When** it asks to change a file in one of those folders, **Then** that counts as inside its work and proceeds at once.
5. **Given** the agent was moved into a worktree, **When** it asks to change a file in that worktree, **Then** the worktree is the folder that counts, and the change proceeds at once.
6. **Given** Cursor is **Auto-review** and Grok is **Default**, **When** each is asked to edit a file in its project, **Then** Cursor proceeds and Grok waits. The two controls do not move together.

---

### User Story 2 - Default still asks, and it is where each setting starts (Priority: P1)

Someone who never opens the setting is asked before an edit. Someone who tries **Auto-review** and switches back gets the cards again, including for an agent that is already working. For Grok, **Default** asks even when Grok's own saved mode would have approved the action.

**Why this priority**: A permission setting that changes behaviour before anyone opts in would surprise every existing chat. Grok also has to stop inheriting a mode that was saved outside the app, or the control would do nothing on a machine where that mode approves everything.

**Independent Test**: On a fresh install, ask a Cursor agent and a Grok agent each to edit a file in the project. Each shows a permission card and waits under **Needs you**. Switch one runtime to **Auto-review**, then back to **Default**, and ask for another edit on that runtime. That edit waits again.

**Acceptance Scenarios**:

1. **Given** the person has never changed a runtime's setting, **When** they look at it, **Then** it is **Default**.
2. **Given** Cursor is **Default**, **When** a Cursor agent asks permission, **Then** the card appears as it does today, with the same buttons, and the agent waits under **Needs you** until it is answered, on the Mac or on the phone.
3. **Given** Grok is **Default**, **When** a Grok agent asks to edit a file or run a command that is not read-only, **Then** a permission card appears and the agent waits under **Needs you**. A read-only action Grok already runs without asking still does, and no card appears for it.
4. **Given** Grok's own settings, outside the app, say to approve every action, **When** the app's Grok control is **Default**, **Then** an agent the app starts still asks, as in scenario 3. Grok started in a terminal is left as it was.
5. **Given** an agent is mid-conversation under **Auto-review**, **When** the person switches that runtime's setting to **Default**, **Then** the next permission request shows a card and waits. A card already on screen stays until they answer it.
6. **Given** the person previously chose **Yes, and don't ask again** for a particular action, **When** the setting is **Default**, **Then** that earlier choice still applies. Actions **Auto-review** allowed on its own are not remembered as "don't ask again", so they wait again under **Default**.

---

### User Story 3 - Auto-review still stops for anything that leaves the project (Priority: P2)

**Auto-review** is not a blanket yes, on either runtime. Pushing, writing outside the project, and anything the app cannot place inside the agent's work still wait for the person, on whichever device they are using.

**Why this priority**: The setting is only safe to turn on if the boundary is visible and reliable. The happy path in story 1 is incomplete without it.

**Independent Test**: With **Auto-review** on for both, ask a Cursor agent and a Grok agent each to edit a file in the home folder, to `git push`, and to run a command with `sudo`. Each request shows the usual permission card and waits under **Needs you**.

**Acceptance Scenarios**:

1. **Given** **Auto-review**, **When** the agent asks to read, create, edit or delete a path outside its project folder and outside any extra folder it was given, **Then** the usual permission card appears and the agent waits.
2. **Given** **Auto-review**, **When** the agent asks to publish or send (`git push`, a force-push, opening or updating a pull request, posting a comment, or sending a message), **Then** the card appears and the agent waits.
3. **Given** **Auto-review**, **When** the agent asks for extra privilege (`sudo`, `su`, `doas`, or an administrator password) or to change the machine outside its work (installing a program for the whole Mac, editing a shell startup file, changing system settings), **Then** the card appears and the agent waits.
4. **Given** **Auto-review**, **When** the agent asks to do something the app cannot tell is confined to its work, **Then** the card appears and the agent waits.
5. **Given** **Auto-review**, **When** the agent asks a question that is not permission to act, **Then** the question is left for the person. Cursor's question card is shown as today. Grok's question still ends the turn, and the agent shows **Waiting on your answer**, as today.
6. **Given** **Auto-review**, **When** the agent asks to start another agent, change a workflow, or take the screen, the simulator or a browser, **Then** the card appears and the agent waits.
7. **Given** a card from scenario 1–4 or 6, **When** the person is on the iPhone or iPad, **Then** the card and the notification arrive there the same way they do today.

---

### User Story 4 - One control each, found in Settings (Priority: P2)

Cursor and Grok each have one control, in one place, covering every agent that runtime starts on this Mac. Claude, Codex, Gemini, Antigravity and Copilot keep the permission modes they already have. The phone has no second copy of either control.

**Why this priority**: A per-chat capsule, or a setting that leaked onto Claude, would be a different feature. The person asked for a global option for the runtimes that do not already offer one.

**Independent Test**: Set both controls to **Auto-review**. Start a Cursor agent and a Grok agent from the prompt, one of them from a workflow, and a Claude agent. The Cursor and Grok agents proceed through an in-project edit with no card. The Claude agent still asks, exactly as it did before the feature existed. Neither prompt grows a permission-mode capsule.

**Acceptance Scenarios**:

1. **Given** the person opens **Settings ▸ Agent Runtimes**, **When** they look at the Cursor row and the Grok row, **Then** each has its own control, labelled as that runtime's permission mode, with **Default** and **Auto-review**, and the selected one is obvious. Each choice has a one-line description of what it allows.
2. **Given** one of those runtimes is not installed, **When** the person opens that pane, **Then** its control is still there and can be changed. It takes effect the next time an agent on that runtime asks.
3. **Given** a runtime's setting is **Auto-review**, **When** a workflow or another agent starts an agent on that runtime, **Then** the new agent follows that runtime's setting.
4. **Given** either setting is **Auto-review**, **When** a Claude, Codex, Gemini, Antigravity or Copilot agent asks permission, **Then** it asks exactly as it does today.
5. **Given** the person looks under a Cursor or Grok prompt, **When** either setting is either value, **Then** no permission-mode capsule appears there. Cursor's Agent, Plan and Ask are unchanged: Plan and Ask still cannot edit or run commands. The capsules Grok already shows stay as they are.
6. **Given** the person quits the app and opens it again, **When** they look at the two controls, **Then** each shows the value they last chose for it.
7. **Given** a project on a server, **When** a Cursor or Grok agent is started there from this Mac, **Then** it follows this Mac's setting for that runtime. The iPhone and iPad show no copy of either control.

---

### Edge Cases

- A permission card is already on screen when the setting changes. That card stays until the person answers it. The new value applies to the next request from an agent on that runtime.
- The agent has no folder the app can name, or the request names no path and is not on the allowed list (build, test, format, package install into the project, local git other than push). The app asks.
- Two agents on the same runtime are working at once. Both follow that runtime's one setting, including an agent that started before the person changed it. The other runtime's agents follow theirs.
- The person answers **No** on a card **Auto-review** decided to show. That action does not proceed, and later actions are judged again from the setting.
- **Auto-review** allows an edit, and the person did not want it. They see it in the conversation and can switch that runtime's setting to **Default**. The feature does not add an undo for that edit.
- A command mixes an in-project path with a path outside it, or pipes work off the machine. The app asks.
- Grok, under **Default**, runs a read or a read-only command that it already runs without asking. No card appears. The same action under **Auto-review** also proceeds.
- Switching only Cursor does not change a Grok agent that is already working, and the reverse.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Settings MUST offer a permission mode for Cursor, on the Cursor row of **Settings ▸ Agent Runtimes**, and a permission mode for Grok, on the Grok row. Each has exactly two choices: **Default** and **Auto-review**. The two controls are independent.
- **FR-002**: Each choice MUST be a single value for the whole Mac. It MUST apply to every agent on that runtime which that Mac starts, in every project, including agents started by a workflow, agents started by another agent, agents already working, and agents whose project is on a server.
- **FR-003**: Until the person changes a control, its value MUST be **Default**.
- **FR-004**: Each choice MUST survive quitting and reopening the app.
- **FR-005**: Under **Default**, every permission request from an agent on that runtime MUST be shown and MUST wait for the person. Cursor's card and buttons stay as they are today. For Grok, an edit or a command that is not read-only waits on a card; a read-only action Grok already runs without asking still does. A mode saved in Grok's own settings MUST NOT change this for an agent the app starts.
- **FR-006**: Under **Auto-review**, the app MUST allow a permission request from that runtime without asking when the action is ordinary work inside the agent's reach. Reach is the folder the agent is working in (its project, or its worktree if it was moved) plus any extra folders it was given at the start. Ordinary work is: creating, editing or deleting a file inside that reach; building, testing, formatting, or installing packages whose files land there; local git other than a push or anything that publishes.
- **FR-007**: Under **Auto-review**, the app MUST still show the usual permission card, and the agent MUST wait under **Needs you**, when the request does any of the following: touches a path outside the agent's reach; publishes or sends (including `git push`, a force-push, a pull request, a comment or a message); asks for extra privilege or an administrator password; changes the machine outside the agent's work; starts another agent, changes a workflow, or takes the screen, a simulator or a browser; or cannot be shown to stay inside the agent's reach.
- **FR-008**: Under **Auto-review**, a question that is not permission to act MUST still be left for the person. Cursor's question card stays as it is. Grok's question still ends the turn, and the agent shows **Waiting on your answer**.
- **FR-009**: An action allowed under **Auto-review** MUST appear in the conversation the same way an approved action does today. It MUST NOT put the agent under **Needs you** and MUST NOT send a notification.
- **FR-010**: Changing one runtime's setting MUST apply to the next permission request from an agent on that runtime. A card already on screen MUST stay until the person answers it. The other runtime's agents are unchanged.
- **FR-011**: An action the person has already marked "don't ask again" MUST stay allowed under either value. An action allowed only because of **Auto-review** MUST be asked again after that runtime's setting returns to **Default**.
- **FR-012**: The settings MUST NOT add a permission-mode control under the Cursor or Grok prompt, MUST NOT change Cursor's Agent, Plan or Ask, and MUST NOT change how Claude, Codex, Gemini, Antigravity or Copilot ask permission.
- **FR-013**: iPhone and iPad MUST NOT grow a copy of either control. Cards that **Auto-review** still shows MUST arrive on the phone and iPad as they do today.
- **FR-014**: Each choice MUST show a one-line description: **Default** asks before that runtime does something that needs permission; **Auto-review** allows ordinary work inside the project and asks before anything that leaves it, publishes, or needs extra privilege.

### Key Entities

- **Permission mode**: One saved choice per runtime, for Cursor and for Grok, either **Default** or **Auto-review**. Cursor's choice is independent of that agent's Agent, Plan or Ask mode. Grok's choice is independent of any permission mode saved in Grok's own settings. Neither choice is a permission mode of Claude, Codex, Gemini, Antigravity or Copilot.
- **Permission request**: The runtime asking before it acts. It names the action (the file, the command, or the tool). It is distinct from a question the person answers in words or by picking a choice.
- **Reach**: The folder the agent is working in, plus any extra folders given when it started. This is the boundary **Auto-review** uses.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person who has the app open can find either control and switch it in under 30 seconds, without starting an agent.
- **SC-002**: With that runtime's **Auto-review** on, a Cursor agent and a Grok agent each complete an in-project file edit and a test run with zero permission cards, zero notifications, and without entering **Needs you**. Both actions are visible in the conversation when the turn ends.
- **SC-003**: With **Auto-review** on, each of these three requests, on each of the two runtimes, produces a permission card within the time a card appears today: a file outside the project, a `git push`, and a command with `sudo`. The agent stays under **Needs you** until the person answers.
- **SC-004**: With **Default**, or after switching back to **Default**, the next in-project edit on that runtime produces a permission card and waits. A fresh install starts both controls on **Default**. A Grok agent the app starts still waits on that edit when Grok's own settings would approve it.
- **SC-005**: After either setting is changed, a Claude agent and a Codex agent ask permission in the same cases they asked before the feature existed. No new permission-mode control appears under a Cursor or Grok prompt.
- **SC-006**: After quitting and reopening, each control shows the value the person last chose for it, and the next permission request on that runtime follows it. Changing Cursor's value does not change Grok's, or the reverse.
- **SC-007**: A card that **Auto-review** still shows can be answered from the iPhone or iPad with the same steps as any other permission card.

## Docs *(mandatory)*

- `docs/reference/settings.md` — add: the Cursor and Grok permission mode controls on the **Agent Runtimes** pane, with **Default** and **Auto-review** and what each does.
- `docs/reference/runtimes.md` — change: the Cursor and Grok rows, so each still offers no permission mode under the prompt, and each says its permission mode lives in **Settings ▸ Agent Runtimes**.
- `docs/how-to/choose-runtime-model-mode.md` — add: Cursor's and Grok's permission modes are those settings, and the capsules under those prompts are unchanged.
- `docs/how-to/answer-a-question.md` — add: with **Auto-review**, ordinary permission requests from that runtime are answered for you, and the ones that still wait are answered the same way as today. Grok's questions in words are unchanged.

## Assumptions

- **Default** and **Auto-review** are the two choices, for each runtime. A third choice that allows every request, including a push and a path outside the project, is out of scope for both.
- The same rules (FR-006 and FR-007) decide **Auto-review** for Cursor and for Grok. Cursor does not offer its own review to the app. Grok has its own modes outside the app; for agents the app starts, this setting is the one that applies, and an unsafe action is asked about rather than blocked silently.
- Each control sits on that runtime's row in **Settings ▸ Agent Runtimes**, beside the other per-runtime controls, rather than on **Agents**, in a new pane, or as one shared switch for both.
- One value per runtime per Mac. It is not per project, per agent, or per workflow, and a workflow file cannot override it. It is not synced to another Mac. The phone and iPad follow the Mac they are paired with.
- Cursor's Agent, Plan and Ask stay as Cursor defines them. The setting only changes what happens when Cursor asks permission, which is while it is allowed to act.
- Grok in a terminal, and any permission mode saved in Grok's own settings, are unchanged. Only agents the app starts follow the app's Grok control.
- "Don't ask again" keeps its current meaning and is not rewritten by this feature.
- When a request is ambiguous, the app asks. That is the safe side of FR-007.
- Package installs that write into the project are ordinary work. Installing software for the whole Mac is not.
- Local git other than push, including fetch and pull, is ordinary work. Push, force-push, and opening or updating a pull request are not.
- Read-only actions Grok already runs without a prompt stay that way under both values. **Default** does not invent new cards for them.
