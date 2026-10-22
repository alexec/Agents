# Feature Specification: Enterprise T5: policy from the control plane

**Feature Branch**: `agents/are-0-11-enterprise-3` (spec only)

**Created**: 2026-10-21

**Status**: Draft. Nothing here is built yet.

**Milestone**: 0.11 Enterprise. Nothing for 0.11 merges to `main` before v0.10.0 ships.

**Input**: Issue #998, roadmap step T5 in `specs/research/733-team-and-enterprise.md`. It builds on the team tier (spec 736, T1–T4, merged), the Console (#1804) and the bot spend caps (FR-033).

## Why this feature exists

**Today each person sets their own limits.**

- A person picks the mode, the sandbox, the runtimes and models, the marketplaces, the cost limits, the helper limits and the variables passed through to runtimes.
- That is correct for one person. It is not enough for an organisation: its IT and security teams must be able to say "no agent here runs with bypass permissions" and know that every machine obeys.

**This feature gives the organisation one policy.**

- An admin writes one policy document on the control plane.
- The control plane signs it and sends it to every machine.
- Each machine enforces it as a ceiling above the person's own settings and the project's settings.
- A choice that the policy refuses says **Set by your organisation**, on the Mac, the Remote and the web page.
- A machine that cannot reach the control plane keeps the last policy it had. It never loosens without a new one.
- MDM on a Mac and `/etc/agents/policy.json` on Linux only say which control plane a machine must join. The rules always come from the control plane.

**A control plane with no policy works as today.** One person sees no change.

## Decisions

| Question | Answer | Who, when |
|---|---|---|
| Where policy comes from | From the control plane. Machines enforce it. MDM only pins which control plane a Mac must join. | Alex, 2026-10-11 (#733) |
| Policy layers | **One document for the organisation** in this spec. Group, person and project layers (the #1804 mock-up) come later, and can only make a rule tighter. The document has a place for them (`groups`), so nothing moves. | Decided 2026-10-21, see Clarifications |
| Where an admin edits it | **Console ▸ Policy on the web page**, because Alex decided that the Console is its own web app (#1804, decision 1). The Mac and the Remote show the policy, read only, in Settings ▸ Control plane ▸ Policy, with the kill switch for admins and **Edit in Console**. | Decided 2026-10-21 |
| Budgets for subscription runtimes | **Two numbers, as a person's own cost limits have today:** dollars and tokens. A subscription runtime reports tokens and no cost, so the token budget holds it. A runtime that reports neither is **unmetered**. While a budget is set, an unmetered runtime is refused unless the admin allows it by name. No price table, no estimates. | Decided 2026-10-21 (the open question on #998, #395) |
| Budget period | Per person, per UTC day, as the bot caps (FR-033) are. The monthly budgets in Report Policy (#1804) stay a line on a report, not a limit. | Decided 2026-10-21 |
| Kill switch | Stops running turns, refuses new agents and new prompts, and pauses every workflow, on every machine, until an admin turns it off. Agents and their conversations are kept. | Decided 2026-10-21 |
| A machine that cannot enforce a rule | It refuses to start agents and says to update Agents Host. | Decided 2026-10-21 |
| The policy on a machine's disk | Signed by the control key. A copy that fails the check counts as no policy. | Decided 2026-10-21 |

## Words

- **Policy**: the organisation's one document of rules. It is kept on the control plane.
- **Rule**: one field of the policy, for example the mode ceiling.
- **Set by your organisation**: the line on a refused choice. It follows the line the user scope already uses on a machine ("This is set under You on the control plane", `agentsd/usersettings.go`).
- **Ceiling**: the loosest value a rule allows. A person's or a project's setting can be the same or tighter, never looser.
- **Effective setting**: what an agent gets: the tightest of the policy, the project's setting and the person's setting.
- **Refused choice**: a choice on a client that the policy does not allow. It is shown, dimmed, with **Set by your organisation**.
- **Kill switch**: one rule that stops all agent work in the organisation.
- **Pin**: the control plane's address and the fingerprint of its key, as a pairing code carries them today.
- **Must join**: an MDM or `/etc` setting that says a machine runs nothing until it has joined the pinned control plane.
- **Unmetered runtime**: a runtime whose turns report neither a cost nor tokens (`unpricedTurns` in the usage roll-up).

## Clarifications

### Session 2026-10-21 (the 0.11 spec lane, decide and tell; Alex can overrule)

- Q: Does a group, a person or a project get its own policy layer?
  → A: **Not in this spec.** One document for the organisation. Groups (T1) are for providers and bot cost only (Alex, 2026-10-15). The document keeps a `groups` field, empty, so that a later spec can add layers that only make a rule tighter, with no migration.
- Q: Where does an admin edit the policy?
  → A: **In the Console, on the web page** (Console ▸ Policy, concept M3 of #1804). Alex decided that the Console is its own app and web only (#1804, decision 1, "admin work at a desk"). The Mac and the Remote get a read-only Policy pane in Settings ▸ Control plane. An admin there also gets the kill switch, because an incident does not wait for a desk, and **Edit in Console**, which opens the web page.
- Q: How do budgets count a subscription runtime, which reports no cost (#395)?
  → A: **With the two numbers a person's own limits already have** (`CostLimits`: `daily` in a currency and `dailyTokens`, and the per-agent pair). The policy is the ceiling over them.
  - A turn with a reported cost counts against the dollar budget. Its tokens count against the token budget too.
  - A subscription runtime (for example Claude on a plan) reports tokens and no cost. The token budget holds it. Tokens are counted as the machines count them today (`limitTokens`: fresh input and output, no cache reads and no thoughts).
  - A turn with neither a cost nor tokens is unmetered (`unpricedTurns` with no tokens).
  - While a budget is set, an unmetered runtime is refused, unless the admin names it in `budgets.allowUnmetered`. A budget that a person can avoid by changing runtime is not a budget.
  - **Not chosen:** pricing tokens at each model's list price. Agents has no price table, the table would go out of date, and the number would be an estimate shown as a fact (constitution IV).
- Q: Does the budget replace the bot caps (FR-033) or the Report Policy budgets (#1804)?
  → A: **Neither.** A bot keeps its own cap and its group's cap. Report Policy's monthly budgets stay a forecast line. The policy's budget is for each person, per UTC day, and is enforced.
- Q: Does the kill switch stop work that is running?
  → A: **Yes.** It is for an incident: a runaway cost or a leaked key. Each machine stops every running turn, as **Stop** does, refuses new agents and prompts, and pauses every workflow and its queue. When the admin turns it off, nothing starts again by itself. Each person sends their next prompt. Paused workflows run again from their next trigger.
- Q: What does "refuses to loosen without one" mean for an offline machine?
  → A: A machine applies the newest policy it has. Only a newer signed policy from the control plane can change it. A machine that has joined an organisation with a policy and has lost its copy (deleted, or it fails the signature check) starts no agent until it gets one.
- Q: Is the policy a security boundary against the machine's own user?
  → A: **No.** Agents Host and `agentsd` run as that user, and never ask for admin rights (Alex, hosts never escalate). A user who edits the binary can avoid the rules. The policy stops mistakes and ordinary use. A signed copy on disk makes an edit to the file useless. MDM makes the Mac's pin hard to remove. The docs say this plainly.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One person sees no change (Priority: P1)

Alex runs a control plane alone. Agents is updated to this version. No policy is set. Every choice that worked before still works, and no choice says **Set by your organisation**.

**Why this priority**: most people use Agents alone. The policy must cost them nothing.

**Independent Test**: update a scratch control plane with two machines and no policy. Start agents in every mode with every sandbox choice. Nothing is refused, and no Policy row says anything is set.

**Acceptance Scenarios**:

1. **Given** a control plane with no policy, **When** a machine joins, **Then** it gets "no policy", and applies no ceiling.
2. **Given** no policy, **When** any client opens Settings ▸ Control plane ▸ Policy, **Then** it says "Your organisation sets no policy."

---

### User Story 2 - An admin sets a ceiling and every machine obeys (Priority: P1)

Priya is an admin. In Console ▸ Policy she sets the mode ceiling to **Accept Edits**, the sandbox to **Required**, and the runtimes to Claude and Codex. Within seconds, Sam's Mac and Sam's Linux server have the policy. Sam opens a new agent: Gemini is dimmed with **Set by your organisation**. The mode menu shows **Auto** and **Bypass Permissions** dimmed with the same line. A running agent of Sam's in **Bypass Permissions** goes down to **Accept Edits** at its next turn, and the chat says why.

**Why this priority**: this is the feature. Without it, the rest is reporting.

**Independent Test**: on a scratch control plane with two people and three machines, set the policy above. On each machine, try to start each runtime and each mode by the wire. Every loose choice is refused with the reason `policy`. Clients draw the refused choices dimmed, with the line.

**Acceptance Scenarios**:

1. **Given** a policy is saved, **When** the control plane keeps it, **Then** every online machine has it within 5 seconds, and an offline machine gets it when it connects.
2. **Given** a mode ceiling, **When** a person, a project setting, a workflow or a helper asks for a looser mode, **Then** the machine refuses it and says **Set by your organisation**. A workflow or helper falls back to the ceiling and says so in the run.
3. **Given** a required sandbox, **When** an agent starts on a runtime with no command sandbox or one that the app cannot vouch for (`none`, `runtimeControlled`), or with the choice `off`, **Then** it is refused. **Continue without sandbox** is not offered. Today that leaves Claude, Codex and Grok (`sandboxCatalog`); Gemini, Cursor, Copilot, Antigravity and OpenCode are refused, and the Console's preview says so before the admin saves.
4. **Given** an allowed runtimes list, **When** a person starts another runtime, or picks a model that is not allowed, **Then** it is refused. A model is matched by its id, with `*` at the end allowed (`claude-sonnet-*`).
5. **Given** a marketplace allowlist, **When** a person adds a skill, plugin or MCP server from a marketplace that is not on it, **Then** it is refused. A marketplace that is not allowed is not shown. With `customServers: refuse`, an MCP server added by hand is refused too.
6. **Given** helper caps, **When** a project's helper limits (`.agents/project.json`, #64) are above them, **Then** the project's value is shown with **Set by your organisation** and the cap is used. Setting a project's limits above the cap is refused.
7. **Given** an environment pass-through list, **When** a runtime's pass-through names a variable that the list does not allow, **Then** that variable is not passed, and Settings shows it dimmed with the line.
8. **Given** a policy that is changed to be looser, **When** machines get it, **Then** the choices come back. Nothing a person set is lost: the person's own setting was kept, only its effect was capped.
9. **Given** a running agent whose mode, model or runtime the new policy refuses, **When** its next turn starts, **Then** the mode goes down to the ceiling, or the turn is refused for a runtime or model that is not allowed, with a line in the chat that says why. A turn that is running is not stopped (only the kill switch does that).

---

### User Story 3 - Every client says "Set by your organisation" (Priority: P1)

Sam uses the Mac, the iPhone and the web page. Wherever a choice is refused, Sam sees it, dimmed, and the line **Set by your organisation**. A tap or a hover shows the rule ("Your organisation allows modes up to Accept Edits").

**Why this priority**: a choice that just fails, with no reason, looks like a bug.

**Independent Test**: with the policy of US2, walk the new-agent form, the mode menu, the model menu, Settings ▸ Agent Runtimes, Settings ▸ Resources (helpers), the marketplace and MCP lists, and the pass-through list on all three clients. Each refused choice is dimmed and says the line.

**Acceptance Scenarios**:

1. **Given** a refused choice, **When** any client draws it, **Then** it is shown, dimmed, not hidden, with **Set by your organisation**. The one exception is a marketplace that is not allowed, which is not listed (its items cannot be added anyway).
2. **Given** a refused call by the wire (an older client, an agent tool, a workflow), **When** the machine answers, **Then** the error has the reason `policy` and the rule's name, and the client shows the same line.
3. **Given** Settings ▸ Control plane ▸ Policy on any client, **When** a member opens it, **Then** it lists each rule that is set, in words, read only, with when the policy was last changed and by whom.

---

### User Story 4 - A person stops at their daily budget (Priority: P2)

The policy gives each person $40 a day. Sam's agents on two machines have spent $38.50 today. Sam's next turn on the Mac goes over $40. Sam's agents finish the turns that are running, and then new turns are refused until midnight UTC. The chat says "You have used today's $40 budget, set by your organisation. It starts again at 00:00 UTC." Sam can send **Ask for More** from that line, which goes to Console ▸ Requests.

**Why this priority**: cost is the first thing an organisation asks to limit, but the other rules can ship first.

**Independent Test**: on a scratch control plane, give a person a budget of $1 and 50,000 tokens, and two machines with the fake runtime: one mode reports a cost per turn, one reports tokens only. Turns go on both machines until a total passes its budget. Then each machine refuses new turns within one roll-up, and at once on the machine that crossed it.

**Acceptance Scenarios**:

1. **Given** a daily budget, **When** a machine adds up its own spend today and it reaches the budget, **Then** that machine refuses new turns at once.
2. **Given** spend on several machines, **When** the control plane adds the machines' roll-ups and the total reaches the budget, **Then** it tells every machine of that person, as it tells a bot's machines today (`host/user` → `capReachedUntil`).
3. **Given** a runtime that reports tokens and no cost (a subscription), **When** its turns pass the daily token budget, **Then** new turns are refused, as for the dollar budget.
4. **Given** a budget and an unmetered runtime not in `allowUnmetered`, **When** a person starts it, **Then** it is refused with **Set by your organisation**, and the tip says "Your organisation cannot measure this runtime's use." Today Cursor, Antigravity and Grok report neither cost nor tokens (`docs/how-to/limit-spending.md`), and a person's own limits never cap them (`unmeasuredMoney`, `unmeasuredTokens`).
5. **Given** a person at the budget, **When** they send **Ask for More**, **Then** an admin sees it in Console ▸ Requests, and can raise that person's budget for today. The raise is kept as an exception on the policy, named and dated, and ends at midnight UTC.

---

### User Story 5 - An admin stops everything (Priority: P2)

A token leaks at 02:00. Priya, an admin, is on her phone. She opens Settings ▸ Control plane ▸ Policy and turns on **Stop All Agent Work**. She confirms. Every machine that is online stops every running turn and pauses every workflow within 5 seconds. Every client shows a red strip: "Your organisation has stopped all agent work." Machines that are offline stop when they connect.

**Why this priority**: an incident is rare, but without a switch an admin has to reach every machine.

**Independent Test**: on a scratch control plane with three machines, two agents working and a scheduled workflow, turn the switch on by the wire. Both turns stop within 5 s. The workflow's next trigger does not run. A new agent is refused. Turn it off: nothing starts by itself, and a new prompt works.

**Acceptance Scenarios**:

1. **Given** the switch is turned on, **When** a machine gets the policy, **Then** it stops each running turn, refuses new agents, prompts and helpers, and pauses every workflow and its queue.
2. **Given** the switch, **When** a client draws any screen, **Then** it shows the strip, and the composer says why it cannot send.
3. **Given** the switch is turned off, **When** machines get the policy, **Then** nothing restarts by itself. Queued prompts stay queued until their person sends them again.
4. **Given** the switch is on, **When** an admin turns it on or off, **Then** the audit trail (T3) records who, and when.

---

### User Story 6 - An offline machine keeps its policy (Priority: P2)

Sam's laptop is on a plane. It has the policy from this morning. Sam starts an agent: the same ceiling applies. Sam deletes the policy file in `~/.agents`. The next start is refused: "Agents Host has no policy from your organisation. Connect to the network."

**Why this priority**: a policy that goes away with the network is no policy.

**Independent Test**: join a scratch machine, set a policy, stop the control plane. The machine still refuses loose choices. Edit the policy file by hand to loosen it: the machine refuses to start agents. Start the control plane: the machine gets the signed policy and starts agents again.

**Acceptance Scenarios**:

1. **Given** an offline machine with a policy, **When** a person makes a choice, **Then** the last policy applies.
2. **Given** a policy file that fails the signature check, or is missing on a machine that had one, **When** an agent starts, **Then** it is refused until the machine gets a policy from the control plane.
3. **Given** a policy older than the one the machine holds (a lower `version`), **When** it arrives, **Then** the machine refuses it and keeps its own.

---

### User Story 7 - IT pins a Mac or a server to the control plane (Priority: P3)

The IT team pushes a configuration profile to every Mac. It names the control plane's address and pin, and says **must join**. Agents Host on a new Mac runs nothing, and shows "Your organisation requires this Mac to join control.acme.dev." until it has joined. The window cannot pair to another control plane. On Linux, `/etc/agents/policy.json`, owned by root, says the same for `agentsd`.

**Why this priority**: it matters to a fleet, and a team can use T5 without it.

**Independent Test**: on a scratch Mac account, put the managed preferences in place with a test profile (or the defaults domain in a test). Agents Host starts no agent before it joins, refuses a code for another control plane, and runs normally after it joins the pinned one. On the devbox container, the same with `/etc/agents/policy.json`.

**Acceptance Scenarios**:

1. **Given** must join and no join yet, **When** anything asks the machine to start an agent, a shell or a workflow, **Then** it is refused with the reason `mustJoin`.
2. **Given** a pin, **When** a code or a join names another address or key, **Then** it is refused, and says which control plane is required.
3. **Given** a pin, **When** the person tries **Leave Control Plane** or **Forget** on that machine, **Then** it is refused with **Set by your organisation**.
4. **Given** an MDM profile or `/etc/agents/policy.json` with any other key (a rule), **When** the machine reads it, **Then** it ignores that key and logs it once. Rules come only from the control plane.

---

### Edge Cases

- **Two admins save at once**: the store's conditional write lets one through. The other is told to load the policy again, as with any record (store rule 3).
- **A policy that no machine can meet** (no runtime allowed): the Console warns before it saves, and saves when the admin confirms.
- **A machine of an older version**: it does not say the policy capability. The control plane sends it nothing, and the Console's Machines page shows it as **Does not follow policy**. If the policy sets `requireFollowing`, that machine's agents are refused by the control plane at the router (the router already sees each start).
- **A rule a machine does not know** (a newer control plane): the policy names the capabilities it needs (`requires`). A machine that lacks one starts no agent, and says "Update Agents Host to follow your organisation's policy."
- **Clock skew**: the budget day is UTC on the control plane. A machine counts its own day by its own clock, and the control plane's `capReachedUntil` wins.
- **A bot**: a bot follows the policy like a person. Its spend caps (FR-033) apply as well; the tighter one wins. The kill switch stops bots too.
- **The local owner alone, with a policy**: a person alone can still set a policy, for their own guard rails. The same rules apply to them.
- **A project setting that is tighter than the policy**: it stays. The policy only caps, it never loosens a project's or a person's setting.
- **Control key rotation (T4)**: a machine trusts the new key as it does today. The policy is signed again with the new key at the next save, and the old signature stays valid for the 30 days the old key is kept.

## Requirements *(mandatory)*

### Functional Requirements

**The document and its store (slice 1)**

- **FR-001**: The control plane MUST keep one policy document per organisation, at `<prefix>/v1/policy.json`, a plain JSON record with `rev`, as every record is. Its fields are in `data-model.md`.
- **FR-002**: The policy MUST have these rules, each optional (absent = no ceiling):
  - `modeCeiling`: the loosest mode, by ModeLooseness rank;
  - `sandbox`: `required` or absent;
  - `runtimes`: allowed runtime ids, each with optional allowed `models` (ids, `*` at the end);
  - `marketplaces`: allowed marketplace ids, and `customServers` (`allow` or `refuse`);
  - `budgets`: per person, `daily` (US dollars), `dailyTokens`, `perAgent` and `perAgentTokens` (the fields of `CostLimits`), `allowUnmetered` (runtime ids), and today's `raises`;
  - `helpers`: `mostRunning` and `mostNotArchived`, the ceiling over each project's helper limits (#64);
  - `environment`: `passThrough`, the variable names (with `*` at the end) that a person's own pass-through list (`runtime-environment.json`, #727) may name. The built-in allowlist and each runtime's own names are not changed here (T6 changes the gateway names);
  - `stopAll`: the kill switch, with who and when;
  - `requireFollowing`: refuse agents on machines that do not follow the policy;
  - `groups`: empty in this spec, kept for later layers.
- **FR-003**: Only an admin MUST be able to read the whole document with its history and change it (`policy/get`, `policy/set`, `policy/stopAll`). Every person MUST be able to read the rules that apply to them (`policy/mine`).
- **FR-004**: Each change MUST raise `version` by one and be signed by the control key (Ed25519 over the canonical JSON of the rules, with `version` and `issued`). The signature MUST be kept beside the document, as `policy.sig`, so any copy can send it without the key.
- **FR-005**: Each change MUST be an audit entry (T3, FR-039) with the actor and the rules that changed, before and after.
- **FR-006**: The control plane MUST send the signed policy to each machine on its channel 0, as `host/policy`, when the machine connects and within 5 seconds of each change, on every copy. A machine that does not say the capability `host.policy.1` MUST get nothing.
- **FR-007**: The policy schema MUST be in `Packages/Wire/daemon.schema.json` (`OrgPolicy`, `SignedPolicy`, `PolicyRefusal`), and the methods in `control.openrpc.json`, generated by `scripts/wire.sh gen` (#1135).

**Enforcement on machines (slice 2)**

- **FR-008**: A machine MUST keep the newest signed policy in `<root>/policy.json`, check its signature with the control key it trusts, and refuse a policy with a lower `version` than its own.
- **FR-009**: A machine MUST apply the policy as a ceiling at every place where a choice is made or used:
  - agent start (`startFor`), helper start (`startSession`), workflow run, Continue in New and Branch;
  - mode and model change (`agents/setOption`, which checks no ceiling today), and a workflow's or helper's `model:`;
  - sandbox resolution (`resolveSandbox`, `agents/setSandbox`) and the failure card;
  - marketplace add and enable, `skills/add`, `mcp/add`, `mcp/add-by-hand`;
  - project helper limits (`projects/setHelperLimits`, `helperLimitRefusal`);
  - the runtime launch environment (`environment`, `launchFor`);
  - the user-scope settings a control plane sends (`ApplyUserSettings`), so a person's own settings from another machine are capped too.
  The effective setting MUST be the tightest of policy, project and person.
- **FR-010**: A refusal MUST be an error with the reason `policy`, the rule's name and the words for the client (`PolicyRefusal`). Choice lists that a machine sends to clients (runtimes, models, modes, marketplaces, pass-through names) MUST mark each refused item with `setBy: "organisation"` and the rule.
- **FR-011**: A machine MUST NOT change or delete a person's or a project's own setting because of the policy. It caps the effect only, so a looser policy gives the person's choice back.
- **FR-011a**: The Go `agentsd` MUST read the person's pass-through list (`<settings>/runtime-environment.json`), which it does not read today, so that the policy has a list to cap.
- **FR-012**: A running agent MUST meet a new policy at its next turn: its mode goes down to the ceiling, and a runtime or model that is now refused refuses the turn, with a line in the chat.
- **FR-013**: A machine that has joined an organisation with a policy, and has none it can trust, MUST start no agent, helper, workflow run or turn, and MUST say why.
- **FR-014**: A machine that lacks a capability named in the policy's `requires` MUST start no agent and MUST say to update Agents Host.
- **FR-015**: The kill switch MUST stop each running turn, refuse new agents, turns and helpers, and pause each workflow and its queue, within 5 seconds of the switch on an online machine. Turning it off MUST restart nothing.

**Budgets (slice 2, with slice 1)**

- **FR-016**: The policy's budgets MUST be a ceiling over the person's own `CostLimits`: each effective limit is the lower of the two. A machine counts as it does today: the reported cost, and `limitTokens` for tokens. A turn with neither is unmetered.
- **FR-017**: A machine MUST refuse new turns once its own count for the person today reaches a budget. The control plane MUST add every machine's roll-up for each person by UTC day (cost in US dollars, and the roll-up's `limitTokens`), and at a budget tell that person's machines with `host/user` → `capReachedUntil`, as for bots (FR-033).
- **FR-018**: While a budget is set, an unmetered runtime MUST be refused, unless it is in `allowUnmetered`.
- **FR-019**: A person at the budget MUST be able to ask for more. The request MUST go to Console ▸ Requests. An admin's raise is for one person and one UTC day, kept in `budgets.raises`, and swept the next day.

**Clients (slices 2 and 3)**

- **FR-020**: The Mac window, the Remote and the web page MUST draw each refused choice dimmed with **Set by your organisation**, and the rule in a tip or a detail line, wherever the choice is: new-agent form, mode menu, model menu, Agent Runtimes, sandbox choice and failure card, Resources (helpers), marketplaces and MCP servers, and pass-through names.
- **FR-021**: All three clients MUST show Settings ▸ Control plane ▸ Policy: the rules in words, read only, with the last change and its actor. On the web page, an admin's **Edit in Console** opens Console ▸ Policy; on the Mac and the Remote it opens the web page.
- **FR-022**: All three clients MUST give an admin the kill switch (**Stop All Agent Work**, with a confirmation), and every person the red strip while it is on.
- **FR-023**: The web page MUST have Console ▸ Policy, for admins: each rule with its control, a preview of what changes for whom ("3 people use Gemini; their agents will be refused"), and Save. Raises of budgets are shown in Console ▸ Requests.
- **FR-024**: The Console's Machines page MUST show whether each machine follows the policy, and which version it has.

**MDM and `/etc` (slice 4)**

- **FR-025**: On a Mac, Agents Host and the window MUST read managed preferences, in their own domains (`com.alexecollins.agents.host`, `com.alexecollins.agents.store`; one profile sets both), with three keys: `ControlPlaneAddress`, `ControlPlaneKey` (the key fingerprint a code carries) and `MustJoin` (bool).
- **FR-026**: On Linux, `agentsd` MUST read `/etc/agents/policy.json` with the same three fields (`controlPlane.address`, `controlPlane.key`, `mustJoin`). It MUST use the file only when root owns it and nobody else can write it.
- **FR-027**: With a pin, a machine and a window MUST refuse to pair, join or move to any other control plane, and refuse to leave the pinned one.
- **FR-028**: With must join and no join, a machine MUST start nothing: no agent, shell or workflow.
- **FR-029**: MDM and `/etc` MUST carry no rule. Any other key MUST be ignored and logged once.

**How later steps hang off it**

- **FR-030**: The policy MUST be the place for later enterprise rules. Each later rule is a new optional field and a new capability in `requires`:
  - **T6 (#999)**: `runtimes.<id>.reach`, the allowed ways to reach the model (`signIn`, `orgKey`, `gateway`), which is the `AccountProfile.reach` of #840. "Policy can require the org path" is `reach: ["orgKey", "gateway"]`. T6 also adds the Antigravity terms switch here.
  - **#840 (several accounts per runtime, PR #2158)**: it needs nothing from T5 to land. Once T6 lands, an account whose `reach` the policy refuses is a refused choice in the account picker, with the line.
  - **T8 (#1001)**: `redaction` (on, and extra patterns), `auditSink` and `retentionDays`. They are rules with no ceiling to a person, so they need only the document and its push.
  - **T7 (#1000)**: `minimumHostVersion`, which a machine below it treats as a missing capability (FR-014).

### Key Entities

- **OrgPolicy**: the rules of FR-002, `version`, `issued`, `changedBy`, `requires`.
- **SignedPolicy**: an OrgPolicy and its signature, the control key's id and the algorithm. It is what machines receive and keep.
- **PolicyRefusal**: the reason `policy` (or `mustJoin`, `noPolicy`, `stopAll`, `budget`), the rule, and the words.
- **Machine pin**: an address, a key fingerprint and must join, from MDM or `/etc`.
- **Budget raise**: a person, a UTC day, an amount, the admin, and the request it answers.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A control plane with no policy shows no change on any client, and every call that worked before still works (test over every start, mode and sandbox call).
- **SC-002**: A saved policy is on every online machine within 5 seconds, also with the machines on two copies of the control plane.
- **SC-003**: For each rule, a test over every path where the choice is made (FR-009) shows no way to get a looser effective setting: 0 escapes in the table test.
- **SC-004**: The kill switch stops every running turn on every online machine within 5 seconds, in 20 tries.
- **SC-005**: A machine with an edited, missing or older policy file starts no agent, in tests for each case.
- **SC-006**: A person's spend or tokens pass the budget by no more than one turn on the machine that crosses it, and by no more than one roll-up (one hour) across machines.
- **SC-007**: Every refused choice on the walk list of US3 shows **Set by your organisation** on the Mac, the Remote and the web page.

## Docs

- `docs/explanation/organisation-policy.md`: add. What a policy is, the ceiling, the offline rule, the kill switch, and what it does not protect against (the machine's own user).
- `docs/how-to/set-an-organisation-policy.md`: add. Console ▸ Policy, each rule, the kill switch.
- `docs/how-to/pin-machines-with-mdm.md`: add. The profile keys, a sample `.mobileconfig`, and `/etc/agents/policy.json`.
- `docs/reference/policy.md`: add. Every field, its values and the client words.
- `docs/explanation/control-plane.md`: change. A section "Policy", and the store keys.
- `docs/how-to/limit-spending.md`: change. A person's budget from the organisation, and how a subscription runtime is counted (tokens).
- `docs/reference/settings.md`: change. The Policy pane, and the line on refused choices.
- `specs/071-web-remote/walks/parity/`: change. A row for each item of FR-020 to FR-022.

## Assumptions

- **The team tier is in place**: people, roles, admins, groups, bots, the audit trail and key lifetimes (spec 736).
- **Sizes**: one policy document, under 64 KiB, about 20 people and 50 machines per control plane, as spec 736 says.
- **Budgets in dollars** are compared with costs reported in US dollars. A cost in another currency counts against the token budget only, until a later spec converts currencies.
- **Not in this spec**: group, person or project layers; approving single MCP servers or skills (Catalogue, M5); org keys and gateways (T6); redaction and audit sinks (T8); SCIM (T9); a policy that differs by machine.
