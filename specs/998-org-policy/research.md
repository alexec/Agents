# Research: Enterprise T5, policy

What exists today, and why each decision in `spec.md` was made. Paths are from `main` at b0915967b.

## What exists

| Thing | Where | What T5 does with it |
|---|---|---|
| Mode looseness | `Go/internal/agentsd/helperstart.go` `modeRanks`, `noLooser` (ranks 0–4). Checked only for helpers and messages to looser agents. `agents/setOption` checks no ceiling. | The policy's mode ceiling uses the same ranks, checked at every path (FR-009). |
| Sandbox | `sandbox.go` `sandboxCatalog`, `resolveSandbox`; `SandboxChoice` runtime/on/off, `SandboxState` on/off/runtimeControlled/none | "Required" refuses `off`, `none` and `runtimeControlled`. |
| Helper limits | `.agents/project.json` `helperLimits` (#64), `helperLimitRefusal` | Policy caps `running` and `notArchived`. |
| Runtimes, models | `runtimes.go` `catalog`; models from ACP options; `startFor` is the one start funnel | Allowed lists, checked at `startFor`, `setOption`, helper and workflow `model:`. |
| Marketplaces | `skillcatalog/marketplaces.go`, `marketplaces/*`, `skills/add`, `mcp/add`, `mcp/add-by-hand` | Allowlist, and `customServers`. |
| Environment | `runtimes.go` `allowed` and each runtime's `passed` (#727). The person's `runtime-environment.json` is not read by Go `agentsd`. | Slice 2a reads it, and the policy cuts it. |
| Cost limits | `cost.go`, `costlimits.go`: `CostLimits{perAgent, daily, perAgentTokens, dailyTokens}`, fails closed; runtimes that report nothing are never capped | The policy is a ceiling over the same four numbers. |
| Bot caps | `controlplane/bots.go` `checkCaps`, `spentToday`, `host/user.capReachedUntil` (USD, UTC day) | Generalised to people, with tokens. |
| Usage roll-ups | `reportledger.go` → `usage/rollup` → `v1/usage/days/<day>/<host>.json` | Adds `limitTokens`. |
| User-scope push | `userscope.go` `host/userSettings`, capability `host.user-settings/1`, hash dedup; `agentsd/usersettings.go` refuses local edits with "set under You on the control plane" | The same pattern for `host/policy`, and the same kind of line. |
| Report Policy | `v1/reports/policy.json`: Totals Only, leads, monthly budgets per group | Unchanged. Not enforced. |
| Console | web only (#1804, decision 1); pages in `Web/src/model/console.ts` | Gains Policy (M3). |
| Roles, audit | `isAdmin`, `actorFor`, `audit.controlActions` | `policy/*` are an admin's, and audited. |
| Kill switch | none; `stopAll` in `turns.go` runs at daemon shutdown | Reused for the switch. |
| #840 accounts (PR #2158, held) | `AccountProfile.reach` (`signIn` today) | T6 adds `orgKey`, `gateway`; the policy's `runtimes.<id>.reach` names the allowed ones. |

## What each runtime reports (for budgets)

From `docs/how-to/limit-spending.md` and `docs/reference/runtimes.md`. A turn is counted by what it carries, never by the runtime's name (constitution II).

| Runtime | Cost | Tokens |
|---|---|---|
| Claude | yes | yes |
| Codex | no | yes |
| Gemini | no | yes |
| Copilot, OpenCode | by what each turn carries | by what each turn carries (neither is listed as "Not measured") |
| Cursor, Antigravity, Grok | no | no (unmetered) |

## Decisions

### D1. Budgets: dollars and tokens, no price table

- **Decision**: the policy's budgets are the four `CostLimits` numbers. Subscription runtimes are held by tokens. Unmetered runtimes are refused under a budget unless allowed by name.
- **Why**: it is what each machine counts and enforces today, so the policy is just a lower ceiling. No estimate is shown as a fact.
- **Not chosen**: one dollar number with tokens priced at list prices (no price table exists, it goes out of date, and the number is an estimate); tokens only (Claude on an API key reports dollars, and admins think in dollars).

### D2. One document, no layers yet

- **Decision**: one organisation document; `groups` kept empty.
- **Why**: groups are for providers and bot cost only (Alex, 2026-10-15). Layers need a "view as" preview and a merge rule, and no one has asked for them yet.
- **Not chosen**: the full org → group → person → project ladder of the #1804 mock-up, in this spec.

### D3. Editing in the web Console; read only on Mac and Remote, with the kill switch

- **Decision**: Console ▸ Policy edits. Every client has a read-only Policy pane, and admins get the kill switch on all three.
- **Why**: Alex decided the Console is web only (#1804). The kill switch is the one admin action that cannot wait for a desk.
- **Not chosen**: a full policy editor on Mac and Remote (against #1804); no Policy pane on Mac and Remote (members would not know the rules).

### D4. Signed policy on disk; version only goes up

- **Decision**: Ed25519 signature by the control key; a lower version is refused; a bad or missing copy on a joined machine means no new work.
- **Why**: hosts run as the user, so file permissions cannot protect it. A signature makes an edit useless, and "refuses to loosen without one" becomes exact.
- **Not chosen**: trusting the file (an edit loosens it); expiring the policy after a time offline (an offline laptop would stop working on a plane).

### D5. Kill switch stops running turns

- **Decision**: the switch stops turns, refuses new work and pauses workflows. Nothing restarts by itself.
- **Why**: an incident (runaway cost, leaked key) needs work to stop now.
- **Not chosen**: only refusing new work (a runaway agent would go on).

### D6. A rule a machine cannot follow refuses work

- **Decision**: `requires` lists capabilities; a machine without one starts nothing and says to update.
- **Why**: a machine that ignores a rule it does not know would loosen the policy without a word.

### D7. MDM carries only the pin

- **Decision**: three keys, in each app's own domain; `/etc/agents/policy.json` the same, used only when root owns it.
- **Why**: Alex's decision (#733): rules come from the control plane. The window is sandboxed, so it reads its own domain, and one profile sets both.
