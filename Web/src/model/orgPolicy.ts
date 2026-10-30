// The organisation's policy (#998, spec 998): one document of rules, kept by the control plane and
// followed by every machine as a ceiling over the person's and the folder's own settings. Its words
// are OrgPolicyWords (Packages/AgentsKit/.../Model/OrgPolicy.swift) on the Mac and the Remote; the
// same here, for Settings ▸ Policy and Console ▸ Policy. Below them, the Console's form: the policy
// as fields an admin types in, back to a policy, and what a change does before it is saved.
import type { AuditActor, CostLimits, FleetMachine, OrgPolicy, PolicyBudgets, PolicyReach, PolicyRefusal, PolicyRuntimeRule, PolicySetBy, PolicyState, PolicyStopAll,
  PolicyView, WireDate }
  from "../protocol/generated";
import type { CallFailed } from "../wire/link";
import { Failure } from "../protocol/generated";

export const setBy = "Set by your organisation";
export const title = "Policy";
export const none = "Your organisation sets no policy.";
export const editPolicy = "Edit Policy";
export const editInPeople = "Edit in People";
/** Under the budgets on Cost, when no budget is reached and none caps a limit of the person's. */
export const budgetFoot = "Your organisation’s budget. A lower limit of your own still applies.";
export const foot = "Your organisation’s admins set these rules in Settings ▸ Policy on the web page. Every machine follows them, also offline. A rule only caps your own settings: they come back when the rule does.";

// The kill switch (spec 998 US5).
export const stopAll = "Stop All Agent Work";
export const resumeAll = "Resume Agent Work";
export const stoppedStrip = "Your organisation has stopped all agent work.";
export const stopTitle = "Stop all agent work?";
export const resumeTitle = "Resume agent work?";
export const resumeMessage = "Nothing starts again by itself. Each person sends their next prompt, and paused workflows run at their next trigger.";
export const stopFoot = "For an incident, such as a leaked key or a runaway cost. Every machine stops at once, also those of bots.";

/** "This stops the 3 agents running now, …". */
export function stopMessage(running: number | undefined): string {
  const now = running === undefined ? "This stops every agent running now on every machine"
    : running === 0 ? "No agent is running now. This stops every machine from starting one"
    : running === 1 ? "This stops the 1 agent running now"
    : `This stops the ${running} agents running now`;
  return `${now}, refuses new agents and prompts, and pauses every workflow, until an admin resumes agent work. Agents and their conversations are kept.`;
}

/** The actor's name, or their id. */
export function actorName(actor: AuditActor): string {
  return actor.userName || actor.user;
}

/** "at 14:05" today, "on 21 Oct at 14:05" before. */
export function when(date: Date, now: Date): string {
  const time = date.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  if (date.toDateString() === now.toDateString()) return `at ${time}`;
  return `on ${date.toLocaleDateString("en-GB", { day: "numeric", month: "short" })} at ${time}`;
}

/** "Version 4, changed by Priya on 21 Oct at 14:05." */
export function changed(policy: OrgPolicy, issued: Date, now: Date): string {
  return `Version ${policy.version}, changed by ${actorName(policy.changedBy)} ${when(issued, now)}.`;
}

/** "Stopped by Priya at 02:04." */
export function stoppedBy(stop: PolicyStopAll, at: Date, now: Date): string {
  return `Stopped by ${actorName(stop.by)} ${when(at, now)}.`;
}

export type ModeName = NonNullable<OrgPolicy["modeCeiling"]>;
/** The modes by ModeLooseness rank, tightest first. */
export const modes: readonly ModeName[] = ["ask", "default", "acceptEdits", "auto", "bypassPermissions"];
export const modeNames: Record<ModeName, string> = {
  ask: "Ask", default: "Default", acceptEdits: "Accept Edits", auto: "Auto", bypassPermissions: "Bypass Permissions",
};

/** RuntimeCatalog's runtimes, by name, for a runtime this page may not be told about. */
export const runtimeNames: Record<string, string> = {
  antigravity: "Antigravity", claude: "Claude", codex: "Codex", copilot: "Copilot", cursor: "Cursor", gemini: "Gemini",
  grok: "Grok", opencode: "OpenCode",
};
export const runtimeIDs: readonly string[] = Object.keys(runtimeNames).sort((a, b) => runtimeName(a).localeCompare(runtimeName(b)));

export function runtimeName(id: string): string {
  return runtimeNames[id] ?? id;
}

/** The runtimes with a command sandbox the app can turn on (sandboxCatalog): "required" refuses the rest. */
export const sandboxed: ReadonlySet<string> = new Set(["claude", "codex", "grok"]);
/** The runtimes whose turns report neither a cost nor tokens (docs/how-to/limit-spending.md): a budget refuses them. */
export const unmetered: ReadonlySet<string> = new Set(["cursor", "antigravity", "grok"]);

/** "$40" or "$40.50". */
export function dollars(amount: number): string {
  return Number.isInteger(amount) ? `$${amount}` : `$${amount.toFixed(2)}`;
}

/** "50,000 tokens". */
export function tokens(count: number): string {
  return `${count.toLocaleString("en-GB")} tokens`;
}

// The ways a runtime reaches the model (#999, T031).

/** "own sign-in", "org key", "gateway". */
export function reachName(reach: string): string {
  return reach === "signIn" ? "own sign-in" : reach === "orgKey" ? "org key" : reach;
}

/** A runtime's reach rule in words: "Org key or gateway only", "Any way". */
export function reachWords(reach: readonly string[]): string {
  const ways = (["signIn", "orgKey", "gateway"] as const).filter((w) => reach.includes(w));
  if (ways.length === 3) return "Any way";
  const named = ways.map(reachName).join(" or ");
  return `${named.charAt(0).toUpperCase()}${named.slice(1)} only`;
}

/** Console ▸ Policy's choice per runtime, as Alex's mock-up names them. */
export type ReachChoice = "any" | "org" | "signIn";
export const reachChoices: readonly ReachChoice[] = ["any", "org", "signIn"];
export const reachChoiceNames: Record<ReachChoice, string> = { any: "Any way", org: "Org key or gateway only", signIn: "Own sign-in only" };

export function reachChoiceOf(reach: readonly PolicyReach[] | undefined): ReachChoice {
  if (!reach) return "any";
  if (reach.length === 1 && reach[0] === "signIn") return "signIn";
  if (!reach.includes("signIn") && reach.length > 0) return "org";
  return "any";
}

export function reachOf(choice: ReachChoice): PolicyReach[] | undefined {
  return choice === "org" ? ["orgKey", "gateway"] : choice === "signIn" ? ["signIn"] : undefined;
}

/** Antigravity's terms, as Console ▸ Policy names the choices. */
export const termsChoices = ["show", "accepted", "refuse"] as const;
export const termsNames: Record<(typeof termsChoices)[number], string> = {
  show: "Show the notice", accepted: "Reviewed by your organisation", refuse: "Do not allow",
};

export interface Rule {
  name: string;
  title: string;
  words: string;
}

function list(names: readonly string[]): string {
  return names.length === 0 ? "None" : `Only ${[...names].sort().join(", ")}`;
}

/** "Only Claude (claude-sonnet-*), Codex". */
function runtimeWords(runtimes: Record<string, PolicyRuntimeRule>): string {
  const ids = Object.keys(runtimes).sort((a, b) => runtimeName(a).localeCompare(runtimeName(b)));
  if (ids.length === 0) return "None";
  // Each runtime named for its ways to the model only (#999).
  if (runtimeIDs.every((id) => runtimes[id] && !runtimes[id]!.models)) return "Every runtime";
  return "Only " + ids.map((id) => {
    const models = runtimes[id]!.models;
    if (!models) return runtimeName(id);
    return models.length === 0 ? `${runtimeName(id)} (no models)` : `${runtimeName(id)} (${models.join(", ")})`;
  }).join(", ");
}

/** "$40 a day, 50,000 tokens a day, $5 an agent"; null when no number is set. */
export function budgetWords(b: PolicyBudgets): string | null {
  const parts: string[] = [];
  if (b.daily !== undefined) parts.push(`${dollars(b.daily)} a day`);
  if (b.dailyTokens !== undefined) parts.push(`${tokens(b.dailyTokens)} a day`);
  if (b.perAgent !== undefined) parts.push(`${dollars(b.perAgent)} an agent`);
  if (b.perAgentTokens !== undefined) parts.push(`${tokens(b.perAgentTokens)} an agent`);
  return parts.length === 0 ? null : parts.join(", ");
}

/** "At most 3 running and 10 not archived in a folder"; null when neither is set. */
export function helperWords(h: { mostRunning?: number; mostNotArchived?: number }): string | null {
  const parts: string[] = [];
  if (h.mostRunning !== undefined) parts.push(`${h.mostRunning} running`);
  if (h.mostNotArchived !== undefined) parts.push(`${h.mostNotArchived} not archived`);
  return parts.length === 0 ? null : `At most ${parts.join(" and ")} in a folder`;
}

/** Each rule the policy sets, in words, in the pane's order. Empty for a policy that sets none. */
export function rules(p: OrgPolicy): Rule[] {
  const out: Rule[] = [];
  if (p.modeCeiling) out.push({ name: "modeCeiling", title: "Modes", words: `Up to ${modeNames[p.modeCeiling] ?? p.modeCeiling}` });
  if (p.sandbox === "required") out.push({ name: "sandbox", title: "Command sandbox", words: "Required" });
  if (p.runtimes) {
    out.push({ name: "runtimes", title: "Runtimes", words: runtimeWords(p.runtimes) });
    // Each runtime's ways to the model (#999).
    for (const id of Object.keys(p.runtimes).sort((a, b) => runtimeName(a).localeCompare(runtimeName(b)))) {
      const reach = p.runtimes[id]!.reach;
      if (reach) out.push({ name: `runtimes.${id}.reach`, title: `${runtimeName(id)} reaches the model by`, words: reachWords(reach) });
    }
  }
  if (p.marketplaces) {
    out.push({ name: "marketplaces", title: "Marketplaces", words: list(p.marketplaces.allowed) });
    out.push({ name: "marketplaces.customServers", title: "MCP servers added by hand",
      words: p.marketplaces.customServers === "refuse" ? "Not allowed" : "Allowed" });
  }
  const budget = p.budgets && budgetWords(p.budgets);
  if (p.budgets && budget) {
    out.push({ name: "budgets", title: "Budget", words: budget });
    if (p.budgets.allowUnmetered.length > 0) {
      out.push({ name: "budgets.allowUnmetered", title: "Unmetered runtimes",
        words: "Allowed: " + p.budgets.allowUnmetered.map(runtimeName).sort().join(", ") });
    }
  }
  const helpers = p.helpers && helperWords(p.helpers);
  if (helpers) out.push({ name: "helpers", title: "Helper sessions", words: helpers });
  if (p.environment) out.push({ name: "environment.passThrough", title: "Variables passed to runtimes", words: list(p.environment.passThrough) });
  const terms = p.notices?.antigravityTerms;
  if (terms && terms !== "show") {
    out.push({ name: "notices.antigravityTerms", title: "Antigravity’s terms",
      words: terms === "refuse" ? "Antigravity is not allowed" : "Reviewed by your organisation" });
  }
  if (p.requireFollowing) out.push({ name: "requireFollowing", title: "Machines", words: "A machine that does not follow this policy starts no agent" });
  return out;
}

/** A policy as policy/mine says it: none when none is set. */
export function viewOf(policy: OrgPolicy | undefined): PolicyView {
  return policy ? { policy } : {};
}

/** The line under a refused choice: the mark's words under **Set by your organisation**. */
export function line(mark: PolicySetBy): string {
  return `${setBy}. ${mark.words}`;
}

/** The organisation's budgets in force for this person today (CostState.organisation), as rows on Cost. */
export function budgetRows(limits: CostLimits | undefined, money: (amount: number, currency: string) => string): Rule[] {
  if (!limits) return [];
  const out: Rule[] = [];
  if (limits.daily) out.push({ name: "budgets.daily", title: "Per day", words: money(limits.daily.amount, limits.daily.currency) });
  if (limits.dailyTokens !== undefined) out.push({ name: "budgets.dailyTokens", title: "Tokens per day", words: tokens(limits.dailyTokens) });
  if (limits.perAgent) out.push({ name: "budgets.perAgent", title: "Per agent", words: money(limits.perAgent.amount, limits.perAgent.currency) });
  if (limits.perAgentTokens !== undefined) out.push({ name: "budgets.perAgentTokens", title: "Tokens per agent", words: tokens(limits.perAgentTokens) });
  return out;
}

/** Whether a host starts no work now (PolicyState.startsNothing): the kill switch, no policy it can trust, or an update. */
export function startsNothing(state: PolicyState | undefined): boolean {
  return !!state && (state.stopAll || state.noPolicy || (state.update?.length ?? 0) > 0 || state.refusal !== undefined);
}

/** Why the composer cannot send to a host now, in its organisation's words, or null when it can. */
export function composerReason(state: PolicyState | undefined): string | null {
  if (state?.refusal) return refusalLine(state.refusal);
  if (state?.stopAll) return `${setBy}. ${stoppedStrip}`;
  return null;
}

/** The refusal in a policyRefused error, or null for any other failure. */
export function refusalOf(error: unknown): PolicyRefusal | null {
  // By its code and data, not instanceof, so a failure from another copy of the link reads the same.
  const failed = error as Partial<CallFailed> | null;
  if (!failed || typeof failed !== "object" || failed.code !== Failure.policyRefused) return null;
  const data = failed.data as Partial<PolicyRefusal> | undefined;
  if (!data || typeof data.reason !== "string" || typeof data.words !== "string") return null;
  return data as PolicyRefusal;
}

/** A refusal as one line: **Set by your organisation** first, except where the words say what to do. */
export function refusalLine(r: PolicyRefusal): string {
  return r.reason === "noPolicy" || r.reason === "mustJoin" ? r.words : `${setBy}. ${r.words}`;
}

// Console ▸ Policy: the policy as the fields an admin types in.

export interface RuntimeField {
  on: boolean;
  /** Model ids, commas between; empty for every model. */
  models: string;
}

export interface PolicyForm {
  mode: ModeName | "";
  sandboxRequired: boolean;
  limitRuntimes: boolean;
  runtimes: Record<string, RuntimeField>;
  limitMarketplaces: boolean;
  marketplaces: string;
  refuseCustomServers: boolean;
  daily: string;
  dailyTokens: string;
  perAgent: string;
  perAgentTokens: string;
  allowUnmetered: string[];
  mostRunning: string;
  mostNotArchived: string;
  limitPassThrough: boolean;
  passThrough: string;
  requireFollowing: boolean;
  /** Each runtime's ways to the model (#999): any way when absent. */
  reach: Record<string, ReachChoice>;
  antigravityTerms: (typeof termsChoices)[number];
}

function names(text: string): string[] {
  return text.split(/[\s,]+/).map((s) => s.trim()).filter((s) => s !== "");
}

function numberText(n: number | undefined): string {
  return n === undefined ? "" : String(n);
}

/** The fields of a policy, or of none: every runtime listed, those the policy allows on. */
export function formOf(p: OrgPolicy | undefined): PolicyForm {
  const runtimes: Record<string, RuntimeField> = {};
  const ids = new Set([...runtimeIDs, ...Object.keys(p?.runtimes ?? {})]);
  for (const id of ids) {
    const rule = p?.runtimes?.[id];
    runtimes[id] = { on: !p?.runtimes || rule !== undefined, models: rule?.models?.join(", ") ?? "" };
  }
  return {
    mode: p?.modeCeiling ?? "",
    sandboxRequired: p?.sandbox === "required",
    limitRuntimes: p?.runtimes !== undefined,
    runtimes,
    limitMarketplaces: p?.marketplaces !== undefined,
    marketplaces: p?.marketplaces?.allowed.join(", ") ?? "",
    refuseCustomServers: p?.marketplaces?.customServers === "refuse",
    daily: numberText(p?.budgets?.daily),
    dailyTokens: numberText(p?.budgets?.dailyTokens),
    perAgent: numberText(p?.budgets?.perAgent),
    perAgentTokens: numberText(p?.budgets?.perAgentTokens),
    allowUnmetered: [...(p?.budgets?.allowUnmetered ?? [])],
    mostRunning: numberText(p?.helpers?.mostRunning),
    mostNotArchived: numberText(p?.helpers?.mostNotArchived),
    limitPassThrough: p?.environment !== undefined,
    passThrough: p?.environment?.passThrough.join(", ") ?? "",
    requireFollowing: p?.requireFollowing === true,
    reach: Object.fromEntries(Object.entries(p?.runtimes ?? {}).filter(([, r]) => r.reach).map(([id, r]) => [id, reachChoiceOf(r.reach)])),
    antigravityTerms: p?.notices?.antigravityTerms ?? "show",
  };
}

/** "40", "$1,200.50"; undefined for nothing; null for anything not an amount. */
function amount(text: string): number | undefined | null {
  const plain = text.trim().replace(/^\$/, "").replace(/,/g, "");
  if (plain === "") return undefined;
  return /^\d+(\.\d{1,2})?$/.test(plain) ? Number(plain) : null;
}

/** "50000", "50,000"; undefined for nothing; null for anything not a whole number. */
function count(text: string): number | undefined | null {
  const plain = text.trim().replace(/,/g, "");
  if (plain === "") return undefined;
  return /^\d+$/.test(plain) ? Number(plain) : null;
}

/**
 * The policy the fields say, on top of the one loaded: what the form does not show (the kill switch,
 * raises, each runtime's ways to the model, the notices, fields of a newer control plane) is kept as it
 * was. The control plane sets version, issued, changedBy and requires itself. A field that is not a
 * number is said in words, and nothing is made.
 */
export function policyOf(form: PolicyForm, base: OrgPolicy | undefined, me: AuditActor): { policy: OrgPolicy } | { problem: string } {
  const p: OrgPolicy = base ? structuredClone(base) : { version: 0, issued: 0 as WireDate, changedBy: me, requires: [] };
  const set = <K extends keyof OrgPolicy>(key: K, value: OrgPolicy[K] | undefined) => {
    if (value === undefined) delete p[key];
    else p[key] = value;
  };
  set("modeCeiling", form.mode === "" ? undefined : form.mode);
  set("sandbox", form.sandboxRequired ? "required" : undefined);
  // A runtime's ways to the model sit on its rule (#999), so a reach rule with no runtime list names every runtime.
  const reached = Object.entries(form.reach).some(([, c]) => c !== "any");
  if (form.limitRuntimes || reached) {
    const runtimes: Record<string, PolicyRuntimeRule> = {};
    for (const [id, field] of Object.entries(form.runtimes)) {
      if (form.limitRuntimes && !field.on) continue;
      const rule: PolicyRuntimeRule = { ...base?.runtimes?.[id] };
      const models = names(field.models);
      if (form.limitRuntimes && models.length > 0) rule.models = models;
      else delete rule.models;
      const choice = form.reach[id] ?? "any";
      // A rule of the kind the form does not name (orgKey alone) is kept while its choice is not changed.
      const kept = base?.runtimes?.[id]?.reach;
      const reach = kept && reachChoiceOf(kept) === choice ? kept : reachOf(choice);
      if (reach) rule.reach = reach;
      else delete rule.reach;
      runtimes[id] = rule;
    }
    set("runtimes", runtimes);
  } else {
    set("runtimes", undefined);
  }
  const notices = { ...base?.notices };
  if (form.antigravityTerms === "show") delete notices.antigravityTerms;
  else notices.antigravityTerms = form.antigravityTerms;
  set("notices", Object.keys(notices).length > 0 ? notices : undefined);
  set("marketplaces", form.limitMarketplaces
    ? { allowed: names(form.marketplaces), customServers: form.refuseCustomServers ? "refuse" : "allow" } : undefined);
  const daily = amount(form.daily), perAgent = amount(form.perAgent);
  const dailyTokens = count(form.dailyTokens), perAgentTokens = count(form.perAgentTokens);
  if (daily === null) return { problem: `“${form.daily}” is not an amount of dollars.` };
  if (perAgent === null) return { problem: `“${form.perAgent}” is not an amount of dollars.` };
  if (dailyTokens === null) return { problem: `“${form.dailyTokens}” is not a number of tokens.` };
  if (perAgentTokens === null) return { problem: `“${form.perAgentTokens}” is not a number of tokens.` };
  if ([daily, dailyTokens, perAgent, perAgentTokens].some((n) => n !== undefined)) {
    const budgets: PolicyBudgets = { allowUnmetered: [...form.allowUnmetered].sort(), raises: base?.budgets?.raises ?? [] };
    if (daily !== undefined) budgets.daily = daily;
    if (dailyTokens !== undefined) budgets.dailyTokens = dailyTokens;
    if (perAgent !== undefined) budgets.perAgent = perAgent;
    if (perAgentTokens !== undefined) budgets.perAgentTokens = perAgentTokens;
    set("budgets", budgets);
  } else {
    set("budgets", undefined);
  }
  const mostRunning = count(form.mostRunning), mostNotArchived = count(form.mostNotArchived);
  if (mostRunning === null) return { problem: `“${form.mostRunning}” is not a number of helper sessions.` };
  if (mostNotArchived === null) return { problem: `“${form.mostNotArchived}” is not a number of helper sessions.` };
  if (mostRunning !== undefined || mostNotArchived !== undefined) {
    set("helpers", { ...(mostRunning !== undefined && { mostRunning }), ...(mostNotArchived !== undefined && { mostNotArchived }) });
  } else {
    set("helpers", undefined);
  }
  const passThrough = names(form.passThrough);
  const wrong = passThrough.find((n) => !/^[A-Za-z_][A-Za-z0-9_]*\*?$/.test(n));
  if (form.limitPassThrough && wrong) return { problem: `“${wrong}” is not a variable name: letters, digits and _, with * at the end allowed.` };
  set("environment", form.limitPassThrough ? { passThrough } : undefined);
  set("requireFollowing", form.requireFollowing ? true : undefined);
  return { policy: p };
}

/** What a saved policy changes from the one in force, rule by rule, in words: "Modes: any → up to Auto". */
export function changes(before: OrgPolicy | undefined, after: OrgPolicy): string[] {
  const was = new Map((before ? rules(before) : []).map((r) => [r.name, r] as const));
  const now = new Map(rules(after).map((r) => [r.name, r] as const));
  const out: string[] = [];
  for (const [name, r] of now) {
    const old = was.get(name);
    if (!old) out.push(`${r.title}: ${r.words}`);
    else if (old.words !== r.words) out.push(`${r.title}: ${old.words} → ${r.words}`);
  }
  for (const [name, r] of was) if (!now.has(name)) out.push(`${r.title}: no longer set`);
  return out;
}

/**
 * What the policy refuses that an admin should know before saving (spec 998 edge cases, US2 3,
 * US4 4): no runtime left, runtimes a required sandbox refuses, runtimes a budget refuses, and
 * machines that cannot follow a policy.
 */
export function warnings(p: OrgPolicy, machines: readonly FleetMachine[] | undefined, routes?: readonly { runtimes: string[] }[]): string[] {
  const out: string[] = [];
  const allowed = p.runtimes ? Object.keys(p.runtimes) : [...runtimeIDs];
  const runnable = allowed.filter((id) => !(p.notices?.antigravityTerms === "refuse" && id === "antigravity"));
  const names = (ids: string[]) => ids.map(runtimeName).sort().join(" and ").replace(/ and (?=.* and )/g, ", ");
  if (runnable.length === 0) out.push("No runtime is left: nobody can start an agent.");
  if (p.sandbox === "required") {
    const refused = runnable.filter((id) => !sandboxed.has(id));
    if (refused.length > 0) {
      out.push(`A required sandbox refuses ${names(refused)}: ${refused.length === 1 ? "it has" : "they have"} no command sandbox the app can turn on.`);
    }
    if (refused.length === runnable.length && runnable.length > 0) out.push("No runtime is left with a command sandbox: nobody can start an agent.");
  }
  if (p.budgets && budgetWords(p.budgets)) {
    const refused = runnable.filter((id) => unmetered.has(id) && !p.budgets!.allowUnmetered.includes(id));
    if (refused.length > 0) {
      out.push(refused.length === 1
        ? `The budget refuses ${names(refused)}: its turns report neither a cost nor tokens. Allow it by name to keep it.`
        : `The budget refuses ${names(refused)}: their turns report neither a cost nor tokens. Allow them by name to keep them.`);
    }
  }
  // The org path only, with no route for it in Model Access (#999): nobody can start that runtime.
  if (routes) {
    for (const id of runnable) {
      const reach = p.runtimes?.[id]?.reach;
      if (!reach || reach.includes("signIn")) continue;
      if (!routes.some((r) => r.runtimes.includes(id))) {
        out.push(`${runtimeName(id)} can reach the model only by an org key or gateway, and no route in Model Access serves it: nobody can start ${runtimeName(id)}.`);
      }
    }
  }
  const old = (machines ?? []).filter((m) => !m.host.capabilities?.includes("host.policy/1"));
  if (old.length > 0) {
    const which = old.map((m) => m.host.name).sort().join(", ");
    out.push(p.requireFollowing
      ? `${old.length === 1 ? "1 machine does" : `${old.length} machines do`} not follow policy and will start no agent: ${which}. Update Agents Host on ${old.length === 1 ? "it" : "them"}.`
      : `${old.length === 1 ? "1 machine does" : `${old.length} machines do`} not follow policy: ${which}. Update Agents Host on ${old.length === 1 ? "it" : "them"}.`);
  }
  return out;
}

/** Console ▸ Machines: "Follows policy v4", "Has v3 of v4", "Does not follow policy", or null with no policy. */
export function followsWords(m: FleetMachine, policy: OrgPolicy | undefined, applied: Record<string, number> | undefined): string | null {
  if (!policy) return null;
  if (!m.host.capabilities?.includes("host.policy/1")) return "Does not follow policy";
  const v = applied?.[m.host.id];
  if (v === undefined) return "Has no policy yet";
  return v >= policy.version ? `Follows policy v${v}` : `Has v${v} of v${policy.version}`;
}

/** The sum of the running agents the machines last listed; undefined when none ever listed. */
export function runningAgents(machines: readonly FleetMachine[] | undefined): number | undefined {
  const counts = (machines ?? []).map((m) => m.running).filter((n): n is number => n !== undefined);
  return counts.length === 0 ? undefined : counts.reduce((a, b) => a + b, 0);
}
