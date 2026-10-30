# Feature Specification: Policy layers: Organisation, You, Folder

**Feature Branch**: `agents/2957-govern-what-agents-may-do` (spec only)

**Created**: 2026-10-30

**Status**: Draft. Nothing here is built yet.

**Milestone**: none yet (backlog). Tier: **Core**, and the Remote reads only at first (see Decisions).

**Input**: Issue #2957 and its mock-up, `specs/research/2957-policy-layers/index.html` (frames A to G). It builds on the organisation policy (spec 998, built), Auto (#2658), the notice limits (#2805), the archive switch (#1802), the workflow limit (#506), the helper limits (#64) and the guarded folder files (#502).

## Why this feature exists

**Today the rules for agents are settings in six places.**

- Agent Runtimes ▸ Auto ▸ Mappings: the permission mode, the permission requests and the sandbox.
- Machines ▸ Spending: the money and token limits, and the workflow limit.
- This app ▸ Notifications: the notice burst and the wait.
- This app ▸ Sidebar: "Agents may archive the chats I start".
- Folder Settings ▸ General: the helper limits of each folder.
- `runtime-environment.json`, a file that the person edits by hand: the variables that agents get.

The organisation policy (spec 998) is a ceiling above some of these. It has its own words, its own pane and its own refusal line. So "What may this agent do?" has no single answer. A person must look in six places and know which ceiling applies.

**This feature puts these rules in one policy, with layers.**

- The layers are **Organisation → You → Folder**. A Group layer comes later (the `groups` slot of spec 998 stays for it).
- Each layer can only make a rule tighter. The tightest value applies.
- Each layer is optional. A rule that no layer sets has today's default.
- Every client shows each value with the layer that sets it.
- When a rule stops an agent, the chat names the rule, the layer and where to change it.

**A person alone sees the same rules as today, in one pane.** Their layer is the top layer, so nothing is locked.

## Decisions

| Question | Answer | Who, when |
|---|---|---|
| Which layers first | **Organisation, You and Folder.** The `groups` slot stays empty, so a Group layer comes later with no change to the format. | Alex, 2026-10-30 |
| Where your layer is kept | **On the Mac's host, signed with your key**, and sent to your other machines. No MCP tool and no folder file can write it. | Alex, 2026-10-30 |
| A folder's layer changed outside the app | A change that only makes the rules tighter applies at once. A change that makes them looser waits for your OK, as `.agents/folder.json` does today (#502). | Alex, 2026-10-30 |
| The name of the organisation's pane | Control plane ▸ Policy becomes **Organisation Policy**, because there are now two policy panes and their names must not be mixed up. | Decided by Claude (#2957). Alex can overrule. |
| Tier | **Core, and the Remote reads only at first.** The Remote keeps the edit of the two rules it edits today (the notice burst and wait, and the archive switch). | Decided by Claude (#2957). Alex can overrule. |
| What "tighter" means for each rule | One order per rule, in the table of FR-004. | Decided by Claude in this spec, because each order is the one the rule's own refusal uses today. Alex can overrule. |
| A folder that wants more than you allow | It cannot have more. A folder's value above yours is capped to yours, and the row says so. To give one folder more helpers, you raise your own value and lower it in the other folders. | Decided by Claude in this spec, because a layer that can loosen a rule breaks "the tightest value applies". Alex can overrule. |
| The helper limits in `.agents/folder.json` | They move to the folder's layer, `.agents/policy.json`. No code reads the old keys (v0.x takes breaking changes). The release notes say what to move. | Decided by Claude in this spec, because one rule must have one place. Alex can overrule. |
| Your values from before | **Read once into your layer** (FR-012), against the v0.x rule of no migration code. A limit that goes away without a word makes the rules looser, so this is the one place where a move is worth its code. The folder files (FR-015) are not moved, because the app must not rewrite committed files in a person's repo. | Decided by Claude in this spec. Alex can overrule. |
| Unmeasured runtimes under your budget | **As today.** Your layer's and a folder's budgets do not cap a runtime that reports neither a cost nor tokens. Only an organisation budget refuses it (spec 998, FR-018). | Decided by Claude in this spec, because a person alone chose those runtimes knowingly. Alex can overrule. |

## Words

- **Policy**: all the rules that say what agents may do. The effective policy is the result of all its layers.
- **Layer**: one source of rules: the **Organisation** (the control plane, spec 998), **You** (the person) or a **Folder** (`.agents/policy.json`).
- **Rule**: one thing that a layer can set, for example the permission mode. Each rule has the same name in every layer.
- **Tighter**: the value that lets agents do less. Each rule has one order (FR-004).
- **Effective value**: what an agent gets: the tightest value of all the layers that set the rule.
- **Decides**: the layer whose value is the effective value. When two layers set the same value, the higher layer decides.
- **Kept, not used**: a value that a layer sets but that a higher layer caps. It stays, and applies again when the cap goes.
- **Capped**: a rule whose value a higher layer limits. It shows 🔒 and the line that says by whom, for example "Acme: at most Approve for me".
- **Same as yours**: a folder row that sets nothing, so your value applies.
- **Stopped by a policy**: the card in a chat when a rule stops an agent.

## Clarifications

### Session 2026-10-30 (from the issue, the mock-up and the code; decide and tell)

- Q: Is the permission mode a ceiling or the mode that agents get?
  → A: **Both.** The effective value is the mode that Auto gives a new agent. It is also the loosest mode that a person, an agent, a helper or a workflow can choose for a session. A person can choose a tighter mode for one session.
- Q: The organisation's `modeCeiling` uses the runtime modes (Ask, Default, Accept Edits, Auto, Bypass Permissions). The mock-up uses Auto's levels (Plan, Ask, Approve for me, Bypass Permissions). Which one does the policy show?
  → A: **Auto's levels**, on every layer and every client. The plan maps the organisation's existing values onto them, and the Console shows the same four words. A runtime's own name for a level stays in Agent Runtimes ▸ Auto.
- Q: What happens to the panes that the rules leave?
  → A: This app ▸ Notifications goes. This app ▸ Sidebar keeps its other rows. Agent Runtimes ▸ Auto keeps only what each runtime calls each level. Spending moves to the Agents group and keeps today's use and the report "What the limits have stopped". Resources moves to the Agents group and stays a setting, because it says what a machine can take, not what an agent may do. Agent Runtimes and Folder ▸ Connectors still set things up; the policy only says what is allowed.
- Q: Can an agent change a rule?
  → A: **No agent can change your layer.** An agent can edit a folder's `.agents/policy.json`, because it is a file in the folder. A change that makes the rules looser waits for your OK. A change that makes them tighter applies at once, and a notice says so.
- Q: Is a layer a security boundary against the machine's own user?
  → A: **No**, as for spec 998. Agents Host and `agentsd` run as that user and never escalate. The layers stop mistakes and ordinary use, and stop an agent from loosening its own rules.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A person alone sets every rule in one pane (Priority: P1)

Alex runs Agents alone. Alex opens **Settings ▸ Agents ▸ Policy**. The pane has five sections: Permissions, Money, Work at once, Your attention and Tools. Each rule that was in another pane before is here, with the value Alex set before. Alex changes the daily budget from $40 to $60. The next turn on every machine of Alex's uses $60. No row shows a lock.

**Why this priority**: most people use Agents alone. One pane must give them every rule, with no loss, before the layers above and below are useful.

**Independent Test**: on a scratch set-up with no control plane, set each rule in the old panes, update to this version, and open Agents ▸ Policy on the Mac and the web page. Every value is there. Change each rule there, and start an agent: each change applies, as it did from the old pane.

**Acceptance Scenarios**:

1. **Given** values set in the old panes, **When** the person opens Agents ▸ Policy, **Then** each rule shows the same value. Nothing is lost, and no row is capped.
2. **Given** Agents ▸ Policy, **When** the person changes a rule, **Then** the next agent start, turn, helper, workflow run or notice uses the new value.
3. **Given** a person alone, **When** the pane opens, **Then** the banner says "You set every limit", with the number of folders that have their own rules, and a link to them (frame C).
4. **Given** an agent, **When** it calls any tool or writes any file to change the person's layer, **Then** the call is refused. Only the person's own clients can change it.
5. **Given** the old panes, **When** the person opens Settings, **Then** This app ▸ Notifications is gone, and Sidebar and Auto no longer show the rules that moved.

---

### User Story 2 - In an organisation, a capped rule says who caps it (Priority: P1)

Sam is a member of Acme. Acme's policy allows at most **Approve for me**. Sam opens Agents ▸ Policy. The banner says "Acme sets limits above yours". The Permission mode row shows 🔒 and "Acme: at most Approve for me". Sam opens the menu: **Bypass Permissions** is dimmed, with "Acme allows at most Approve for me". Sam's daily budget is $40 and Acme's is $100, so Sam's $40 applies and the row has no lock.

**Why this priority**: two ceilings with no link between them are why this feature exists. A capped value that does not say why looks like a bug.

**Independent Test**: on a scratch control plane, set an organisation policy with a value for each rule, half tighter and half looser than the person's. On the Mac and the web page, every rule the organisation caps shows 🔒 and the line, and every menu dims the values above the cap. The rules it does not cap show no mark.

**Acceptance Scenarios**:

1. **Given** an organisation rule tighter than yours, **When** any client draws the row, **Then** it shows 🔒, the effective value, and the line that names the organisation and its value.
2. **Given** a capped rule, **When** the person opens its menu or its number field, **Then** the values above the cap are shown, dimmed, with the reason. They are not hidden.
3. **Given** a capped rule, **When** the person sets a value above the cap, **Then** the value is kept as theirs and the row says "Kept, not used". The cap applies.
4. **Given** the organisation loosens or removes the rule, **When** the machines get the new policy, **Then** the person's kept value applies again. Nothing the person set is lost.
5. **Given** Settings ▸ Control plane, **When** a member opens it, **Then** the pane that was called Policy is called **Organisation Policy**.

---

### User Story 3 - A folder makes the rules tighter for its own agents (Priority: P2)

The payments-api folder must not run commands without asking. Alex opens **Folder Settings ▸ Policy** for it. Each row says **Same as yours**. Alex sets Permission mode to **Ask** and helpers running to 2. The app writes `.agents/policy.json` in the folder, and Alex commits it. Bob opens the same folder on his Mac and gets the same rules.

Later, an agent in payments-api edits `.agents/policy.json` and sets Permission mode back to Same as yours. That is looser, so it waits. A card says what changed and offers **Allow**, **Keep Ask** and **Show Change** (frame D).

**Why this priority**: some folders need tighter rules than the person who opens them. It is less frequent than the person's own rules.

**Independent Test**: on a scratch folder, set two rules in Folder Settings ▸ Policy. The file is written, and the folder's agents get the tighter values while the person's other folders do not. Edit the file by hand to make one rule tighter: it applies at once, with a notice. Edit it to make one rule looser: the card appears, and the old value applies until Allow.

**Acceptance Scenarios**:

1. **Given** a folder with no `.agents/policy.json`, **When** Folder Settings ▸ Policy opens, **Then** every row says Same as yours, with your value.
2. **Given** a folder row, **When** the person opens its menu, **Then** the values looser than the person's effective value are dimmed, with "Your policy allows at most …".
3. **Given** a change made in the app, **When** it is saved, **Then** it applies at once and the file is written in a stable order, so a diff shows only the changed rule.
4. **Given** a change to the file from outside the app (an agent, a pull, a branch change), **When** it only makes rules tighter, **Then** it applies at once and a notice says so.
5. **Given** a change to the file from outside the app, **When** it makes any rule looser, **Then** the last approved values apply until the person allows it, as for `.agents/folder.json` (#502). Undo puts back the last approved file.
6. **Given** a folder value that is looser than yours (for example, written before you tightened your own), **When** an agent starts, **Then** your value applies, and the folder row shows "Capped by yours".

---

### User Story 4 - Where a value comes from (Priority: P2)

Sam's daily budget row says $25.00 applies. Sam taps **Where this comes from**. A popover lists the layers from the top down: Acme $100, You $40 "Kept, not used", Folder not set. The layer that decides is lit (frame B).

**Why this priority**: with three layers, a person must see which layer decides, to know whom to ask or what to change.

**Independent Test**: with a value set in each layer, and the tightest in each layer in turn, open Where this comes from for one rule on the Mac and the web page. Each time, the lit layer is the tightest one, and the other layers show their values or "Not set".

**Acceptance Scenarios**:

1. **Given** any rule, **When** the person opens Where this comes from, **Then** it shows every layer, from the top down, with its value or "Not set", and lights the layer that decides.
2. **Given** a capped value of yours, **When** the popover shows it, **Then** it says "Kept, not used", and a line says that it applies again if the layer above changes.
3. **Given** a folder layer, **When** the popover shows it, **Then** it names the file, `.agents/policy.json`, and says it is committed with the folder's code.

---

### User Story 5 - When a rule stops an agent, the chat says which (Priority: P2)

An agent in payments-api wants to run a command. The folder's layer allows **Ask**, so the agent asks. The card in the chat says "Stopped by a policy", the rule (Permission mode), the layer (payments-api), and **Change in Folder Settings ▸ Policy** (frame E). Later, the day's spending reaches Acme's budget. The card names Acme, says when turns start again, and offers **Ask for More** and **Open Spending**.

**Why this priority**: a stop with no reason looks like a fault. Today only some refusals say "Set by your organisation".

**Independent Test**: for each rule, make a layer stop an agent on a scratch set-up (one stop for each layer). Each chat card names the rule and the layer. The Change action opens the pane of that layer, and only for a layer that the person can edit.

**Acceptance Scenarios**:

1. **Given** a refusal by any rule, **When** the chat draws it, **Then** the card says "Stopped by a policy", the rule, the layer that decides, and the value.
2. **Given** a layer that the person can edit (You, or a folder), **When** the card draws, **Then** it offers **Change**, which opens that layer's pane at the rule.
3. **Given** the organisation decides, **When** the card draws, **Then** it offers no Change. It offers **Ask for More** for a budget (spec 998, FR-019), and **See Organisation Policy** for any other rule.
4. **Given** a refusal by the wire (an older client, an agent tool, a workflow), **When** the machine answers, **Then** the error names the rule and the layer, so every client can draw the same card.

---

### User Story 6 - Your layer is the same on every machine you use (Priority: P3)

Alex has a Mac and a Linux server. Alex sets the per-agent budget to $5 on the Mac. A minute later, an agent on the server stops at $5. The server is offline for a day. It keeps the last layer it had. When it connects again, it gets the new one.

**Why this priority**: a rule that holds on one machine only is not a policy, but most people use one Mac.

**Independent Test**: on a scratch set-up with a Mac host and the devbox, change your layer on the Mac. The devbox applies it. Edit the copy on the devbox by hand: the devbox keeps its last good copy and logs the failed check. Stop the link, change the layer, start the link: the devbox gets the newest copy.

**Acceptance Scenarios**:

1. **Given** a change to your layer, **When** it is saved, **Then** every online machine of yours has it within 5 seconds, and an offline machine gets it when it connects.
2. **Given** a copy of your layer that fails the signature check, **When** a machine reads it, **Then** the machine keeps its last good copy and logs the failure once.
3. **Given** a copy older than the one a machine has, **When** it arrives, **Then** the machine keeps its own.
4. **Given** a control plane, **When** it stores and forwards your layer, **Then** it cannot change it: a copy that the control plane changes fails the signature check.

---

### Edge Cases

- **No layer sets a rule**: the effective value is today's default for that rule (for example 3 helpers running, 20 workflows, a burst of 3 notices and a wait of 10 minutes).
- **Two layers set the same value**: the higher layer decides. The line names it.
- **A machine of an older version**: it does not say the policy-layers capability. It keeps applying the organisation policy and its old settings. A client that edits your layer says which machines do not follow it yet.
- **An invalid `.agents/policy.json`** (not JSON, or an unknown value): the last approved copy applies, and the card says what is wrong. An unknown rule name is ignored and logged once, so a newer folder file works on an older machine.
- **A branch change or a pull changes `.agents/policy.json`**: as any change from outside the app (US3, scenarios 4 and 5).
- **A folder with several worktrees**: each worktree reads its own copy of the file, and has its own approved copy.
- **A running agent when a rule becomes tighter**: it meets the new value at its next turn, as for the organisation policy (spec 998, FR-012). A running turn is not stopped. Only Stop All Agent Work stops one.
- **A workflow or a helper with its own looser setting** (a `model:` or a mode in its file): the effective value caps it, and the run says so.
- **Two clients change your layer at once**: the store's revision lets one through. The other client is told to load the layer again.
- **Stop All Agent Work**: no change. Only the organisation layer has it.
- **Resources (build, simulator, screen)**: not a rule. They stay a setting of each machine.
- **A bot**: it follows the organisation layer and its folder layers. It has no You layer. Its own spend caps (spec 736, FR-033) still apply.

## Requirements *(mandatory)*

### Functional Requirements

**The rules and the layers**

- **FR-001**: The policy MUST have three layers, from the top down: **Organisation**, **You** and **Folder**. The format MUST keep the `groups` slot, empty, for a later Group layer between Organisation and You.
- **FR-002**: Every layer MUST be able to set the same rules, each optional:
  - Permissions: **permission mode** (Plan, Ask, Approve for me, Bypass Permissions), **permission requests** (Ask me, Approve for me), **sandbox** (Off allowed, The runtime's, On);
  - Money: **per agent** and **per day**, each in money and in tokens;
  - Work at once: **helpers running** and **helpers not archived** in each folder, **workflows turned on** in each folder;
  - Your attention: **notices in a burst**, **wait after a burst**, **agents may archive the chats I start**;
  - Tools: **runtimes and models** allowed, **marketplaces** allowed and **connectors added by hand** (allow or refuse), **environment variables** that agents get.
- **FR-003**: The organisation layer MUST add the rules that it does not have today (permission requests, workflows, notices, the archive switch) as optional fields. Its other fields MUST keep their meaning. Stop All Agent Work, the unmetered allowlist and the budget raises MUST stay on the organisation layer only.
- **FR-004**: Each rule MUST have one order from loosest to tightest, the same in every layer:

  | Rule | Tighter is |
  |---|---|
  | Permission mode | lower: Bypass Permissions → Approve for me → Ask → Plan |
  | Permission requests | Ask me |
  | Sandbox | Off allowed → The runtime's → On |
  | Money and tokens | less |
  | Helpers, workflows, notices in a burst | fewer |
  | Wait after a burst | longer |
  | Agents may archive my chats | off |
  | Runtimes, models, marketplaces, variables | fewer: a name that a layer leaves out is not allowed |
  | Connectors added by hand | refuse |

- **FR-005**: The effective value of a rule MUST be the tightest value of every layer that sets it. A rule that no layer sets MUST have today's default.
- **FR-006**: A machine MUST NOT change or delete a layer's value because a higher layer caps it. It caps the effect only, so the value applies again when the cap goes.
- **FR-007**: A machine MUST use the effective value at every place where the rule applies today: agent start, helper start, workflow run, Continue in New and Branch, mode and model changes, sandbox resolution, the permission flow, marketplace and connector adds, the turn and day budgets, the notice limit, archive requests, and the runtime launch environment.
- **FR-008**: The permission mode's effective value MUST be the mode that Auto gives a new agent, and the loosest mode that a person, an agent, a helper or a workflow can choose. A person MUST be able to choose a tighter mode for one session.

**Your layer**

- **FR-009**: Your layer MUST be kept on the Mac's host, signed with a key that only you hold, and sent to each of your other machines when it connects and within 5 seconds of each change.
- **FR-010**: Only your own clients MUST be able to change your layer. A call from an agent, an MCP tool, a workflow or a folder file MUST be refused.
- **FR-011**: A machine MUST check the signature of your layer, keep the newest good copy, and refuse an older copy or one that fails the check.
- **FR-012**: On the first start of this version, your layer MUST be made from the values you set before: Auto's mappings, the cost limits, the workflow limit, the notice limits, the archive switch and `runtime-environment.json`. After that, the old places MUST NOT be read.
- **FR-013**: Where a control plane keeps the person's settings today (the `costLimits` and `notifications` parts of the user scope), it MUST store and forward your signed layer instead, and MUST NOT be able to change it.

**A folder's layer**

- **FR-014**: A folder's layer MUST be the file `.agents/policy.json` in the folder, with only the rules that the folder sets. The app MUST write it in a stable order.
- **FR-015**: A folder's helper limits (running, not archived) MUST move from `.agents/folder.json` to `.agents/policy.json`. No code MUST read the old keys.
- **FR-016**: A change to `.agents/policy.json` from outside the app that only makes rules tighter MUST apply at once, with a notice. A change that makes any rule looser MUST wait for your OK, with the same card, Keep and Undo as a guarded `.agents/folder.json` change (#502). Until then, the last approved copy MUST apply.
- **FR-017**: A folder's layer MUST apply to the agents, helpers and workflows that run in that folder, and to no others.

**Clients**

- **FR-018**: Settings MUST have a new group, **Agents**, with **Policy**, **Spending** and **Resources**, on the Mac window and the web page. Spending and Resources move to it. Spending keeps today's use and the report "What the limits have stopped".
- **FR-019**: Agents ▸ Policy MUST edit your layer, in the sections of FR-002. Each row MUST show its effective value. A capped row MUST show 🔒 and the line that names the layer that decides and its value. A menu MUST show the values above a cap dimmed, with the reason.
- **FR-020**: Each row MUST offer **Where this comes from**, which shows every layer from the top down with its value or "Not set", lights the layer that decides, and marks a capped value of yours as "Kept, not used".
- **FR-021**: The banner at the top of Agents ▸ Policy MUST say who sets limits above yours, with a link to Organisation Policy, or, for a person alone, "You set every limit" and the folders that have their own rules.
- **FR-022**: **Folder Settings ▸ Policy** MUST edit the folder's layer. Each row MUST start at **Same as yours** and show your value. The values looser than yours MUST be dimmed.
- **FR-023**: The rules MUST leave their old panes: This app ▸ Notifications goes; This app ▸ Sidebar loses the archive switch; Agent Runtimes ▸ Auto keeps only each runtime's name for each level; Spending loses the limit fields; Folder Settings ▸ General loses the helper limits.
- **FR-024**: Control plane ▸ Policy MUST be renamed **Organisation Policy** on every client. The Console MUST show the new organisation rules of FR-003, and the permission mode in the words of FR-002.
- **FR-025**: When a rule stops an agent, the chat MUST show a **Stopped by a policy** card with the rule, the layer that decides and the value. It MUST offer **Change** for a layer that the person can edit, and **Ask for More** or **See Organisation Policy** for the organisation.
- **FR-026**: A refusal by the wire MUST carry the rule, the layer and the words, so every client draws the same card. Choice lists that a machine sends MUST mark each capped item with the layer and the rule, as spec 998's `setBy` does for the organisation today.
- **FR-027**: The Remote MUST show Agents ▸ Policy, Where this comes from and the Stopped by a policy card. It MUST keep the edit of the rules it edits today (the notice burst and wait, and the archive switch). The rest is read only on the Remote at first, with a parity issue for the rest.

### Key Entities

- **Policy rules**: the optional fields of FR-002. The same shape in every layer.
- **Organisation layer**: today's `OrgPolicy` (spec 998) with the new fields of FR-003, signed by the control key.
- **Your layer**: the rules, a revision, when it was changed and from which client, and a signature by your key.
- **Folder layer**: the rules in `.agents/policy.json`, and the last approved copy on each machine.
- **Effective policy**: for each rule, its value, the layer that decides, and each layer's value. It is what a machine uses and what a client draws.
- **Policy refusal**: today's `PolicyRefusal`, with the layer added.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person who updates loses none of their own values: for each rule, the value in Agents ▸ Policy after the update is the value set before it (test over every rule). A folder's old helper limits are the one exception, and the release notes say how to move them.
- **SC-002**: A person answers "What may agents do here?" from one pane: every rule of FR-002 is on Agents ▸ Policy, and none is left in another pane.
- **SC-003**: For each rule and each pair of layers, a table test over every place of FR-007 shows no way to get a looser effective value than the tightest layer: 0 escapes.
- **SC-004**: An agent cannot loosen any rule by itself: 0 of the agent-tool and file paths in the test change your layer, and 0 change a folder's layer to looser without your OK.
- **SC-005**: A change to your layer is on every online machine of yours within 5 seconds.
- **SC-006**: Every capped row, and every Stopped by a policy card, names the layer that decides, on the Mac, the web page and the Remote.

## Docs *(mandatory)*

- `docs/explanation/policy-layers.md` — add: the three layers, "tighter only", the effective value, kept values, and what a layer does not protect against (the machine's own user).
- `docs/how-to/set-rules-for-a-folder.md` — add: Folder Settings ▸ Policy, `.agents/policy.json`, committing it, and what happens to a change made outside the app.
- `docs/reference/policy.md` — change: the rules of every layer, their order (FR-004), the new organisation fields, and the client words.
- `docs/reference/agents-folder.md` — change: `.agents/policy.json`, and the helper limits that leave `.agents/folder.json`.
- `docs/reference/settings.md` — change: the Agents group, Agents ▸ Policy, Organisation Policy, and the panes that lose rules.
- `docs/explanation/organisation-policy.md` — change: the organisation is the top layer; the pane is now Organisation Policy.
- `docs/how-to/set-an-organisation-policy.md` — change: the new organisation rules and the four permission levels.
- `docs/how-to/limit-spending.md` — change: the limits are set in Agents ▸ Policy; Spending keeps the report.
- `docs/how-to/mute-notifications.md` — change: the notice burst and wait are in Agents ▸ Policy.
- `docs/how-to/use-auto.md` — change: the permission mode, the permission requests and the sandbox are in Agents ▸ Policy.
- `specs/071-web-remote/walks/parity/settings-and-project-settings.md` and `notifications-and-badges.md` — change: a row for Agents ▸ Policy, Folder Settings ▸ Policy and Where this comes from; the Notifications row goes.
- `specs/071-web-remote/walks/parity/chat-turns-and-turn-detail.md` — change: a row for the Stopped by a policy card.

## Assumptions

- **Spec 998 is built** (checked 2026-10-30): the signed organisation policy, its push, and its enforcement at each place of FR-007. This feature adds layers below it; it does not change how the organisation's policy reaches machines.
- **"Your key"** is a key that only the person's own clients and Mac host hold, so a machine can tell that your layer came from you. The plan says which key (a paired client key, or a key of its own) and how a new client gets it.
- **Without a control plane**, your layer reaches your other machines on the links that carry your settings today. A person with one Mac and no other machine needs no link.
- **The Remote loses nothing**: it keeps the edit of the two rules it edits today (Decisions). Editing the other rules on the Remote is a later parity issue.
- **Sizes**: a layer is under 16 KiB; a person has under 10 machines and under 200 folders with their own layer.
- **Not in this spec**: the Group layer; a layer for each machine; rules that differ by runtime; approving single MCP servers or skills; Resources as a rule.
