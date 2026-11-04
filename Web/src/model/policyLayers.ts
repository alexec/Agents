// Agents ▸ Policy's words and rows (#2957, FR-019 to FR-021; contracts/policy-layers-api.md "Client words"), as
// PolicyLayersWordsTests checks them in Swift (Packages/AgentsKit/.../PolicyLayersWords.swift). The machine resolves
// the layers and sends each rule's words and cap line; these are the page's own: the sections, the titles, what a
// menu offers, and which of its values a cap dims.
import type {
  BudgetRequest, EffectivePolicy, EffectiveRule, GuardedChangePolicy, JSONValue, PolicyBehindMachine, PolicyLayerRef, PolicyRefusal,
  PolicyRuleLine, PolicyRules, UntrustedYourPolicy,
} from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { absolutePath } from "./fileWatch";
import { dollars } from "./orgPolicy";

export const groupTitle = "Agents";
export const title = "Policy";
export const organisationTitle = "Organisation Policy";
export const notSet = "Not set";
export const keptNotUsed = "Kept, not used";
export const sameAsYours = "Same as yours";
export const cappedByYours = "Capped by yours";
export const whereFrom = "Where this comes from";
export const decides = "Decides";
export const folderFile = "committed with the folder’s code";
export const toolsFoot = "Agent Runtimes and Connectors set these up. Here you see what the layers allow.";
export const foot = "Agents, helpers and workflows can’t change these. Each rule only gets tighter from layer to layer: the tightest value applies.";

/** The banner's first line (FR-021): who sets limits above yours, or no one. */
export function banner(policy: EffectivePolicy): string {
  return policy.organisation ? `${policy.organisation} sets limits above yours` : "You set every limit";
}

/** The banner's second line for a person alone: how many folders set their own rules. */
export function foldersLine(count: number): string {
  if (count === 0) return "No folder has its own rules.";
  if (count === 1) return "1 folder has its own rules.";
  return `${count} folders have their own rules.`;
}

/** How many rules a folder in the banner's list sets. */
export function rulesCount(count: number): string {
  return count === 1 ? "1 rule" : `${count} rules`;
}

/** The machines that do not follow the layers yet; null with none. */
export function behindLine(machines: PolicyBehindMachine[]): string | null {
  if (machines.length === 0) return null;
  const names = machines.map((m) => m.name).sort().join(", ");
  const one = machines.length === 1;
  return `${names} ${one ? "does" : "do"} not follow your policy yet. Update ${one ? "it" : "them"} to the newest version.`;
}

/** How "Where this comes from" names a layer: the folder's by its file. */
export function layerLine(layer: PolicyLayerRef): string {
  if (layer.kind === "you") return "You";
  if (layer.kind === "folder") return `${layer.name} (.agents/policy.json)`;
  return layer.name;
}

export type Section = "permissions" | "money" | "workAtOnce" | "attention" | "tools";
export const sections: readonly Section[] = ["permissions", "money", "workAtOnce", "attention", "tools"];
export const sectionTitles: Record<Section, string> = {
  permissions: "Permissions", money: "Money", workAtOnce: "Work at once", attention: "Your attention", tools: "Tools",
};

/** How a row is edited. A choice lists its values loosest first; a number is tighter when lower, unless
 * higherIsTighter. */
export type Kind =
  | { kind: "choice"; order: string[] }
  | { kind: "money" }
  | { kind: "tokens" }
  | { kind: "count"; numbers: number[]; higherIsTighter: boolean }
  | { kind: "toggle" }
  | { kind: "list" };

export interface Row {
  rule: string;
  title: string;
  section: Section;
  kind: Kind;
  /** What applies when no layer sets it. */
  unset: string;
}

const range = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => from + i);
/** The cool-downs the Mac and the Remote offer (DisplayPreference.noticeCooldownPresets). */
export const waitPresets = [1, 5, 10, 15, 30, 60, 120, 240, 480, 1440];

export const rows: readonly Row[] = [
  { rule: "permissionMode", title: "Permission mode", section: "permissions",
    kind: { kind: "choice", order: ["bypassPermissions", "approveForMe", "ask", "plan"] }, unset: "Ask, and any mode may be chosen" },
  { rule: "permissionRequests", title: "Permission requests", section: "permissions",
    kind: { kind: "choice", order: ["alwaysApprove", "default"] }, unset: "Each runtime’s" },
  { rule: "sandbox", title: "Sandbox", section: "permissions", kind: { kind: "choice", order: ["off", "runtime", "on"] }, unset: "Each runtime’s" },
  { rule: "budgets.perAgent", title: "Per agent", section: "money", kind: { kind: "money" }, unset: "No limit" },
  { rule: "budgets.perAgentTokens", title: "Tokens per agent", section: "money", kind: { kind: "tokens" }, unset: "No limit" },
  { rule: "budgets.daily", title: "Per day", section: "money", kind: { kind: "money" }, unset: "No limit" },
  { rule: "budgets.dailyTokens", title: "Tokens per day", section: "money", kind: { kind: "tokens" }, unset: "No limit" },
  { rule: "helpers.mostRunning", title: "Helpers running in each folder", section: "workAtOnce",
    kind: { kind: "count", numbers: range(1, 10), higherIsTighter: false }, unset: "3" },
  { rule: "helpers.mostNotArchived", title: "Helpers not archived in each folder", section: "workAtOnce",
    kind: { kind: "count", numbers: range(1, 20), higherIsTighter: false }, unset: "5" },
  { rule: "workflows.mostOn", title: "Workflows turned on in each folder", section: "workAtOnce",
    kind: { kind: "count", numbers: range(1, 100), higherIsTighter: false }, unset: "20" },
  { rule: "noticeLimits.burst", title: "Notices in a burst", section: "attention",
    kind: { kind: "count", numbers: range(1, 20), higherIsTighter: false }, unset: "3" },
  { rule: "noticeLimits.waitMinutes", title: "Wait after a burst", section: "attention",
    kind: { kind: "count", numbers: waitPresets, higherIsTighter: true }, unset: "10 minutes" },
  { rule: "archiveMyChats", title: "Agents may archive the chats I start", section: "attention", kind: { kind: "toggle" }, unset: "On" },
  { rule: "runtimes", title: "Runtimes and models", section: "tools", kind: { kind: "list" }, unset: "Every runtime and model" },
  { rule: "marketplaces.allowed", title: "Marketplaces", section: "tools", kind: { kind: "list" }, unset: "Every marketplace" },
  { rule: "marketplaces.customServers", title: "Connectors added by hand", section: "tools", kind: { kind: "list" }, unset: "Allowed" },
  { rule: "environment", title: "Variables agents get", section: "tools", kind: { kind: "list" }, unset: "Each runtime’s own" },
];

export function rowsIn(section: Section): Row[] {
  return rows.filter((r) => r.section === section);
}

const permissionWords: Record<string, string> = {
  plan: "Plan", ask: "Ask", approveForMe: "Approve for me", bypassPermissions: "Bypass Permissions",
};

/** A choice's words, as the machine says them. */
export function choice(rule: string, raw: string): string {
  if (rule === "permissionMode") return permissionWords[raw] ?? raw;
  if (rule === "permissionRequests") return raw === "default" ? "Ask me" : raw === "alwaysApprove" ? "Approve for me" : raw;
  if (rule === "sandbox") return ({ off: "Off allowed", runtime: "The runtime’s", on: "On" } as Record<string, string>)[raw] ?? raw;
  return raw;
}

/** "10 min", "1 hour", "4 hours", as the window's notice menu says them. */
export function minutes(n: number): string {
  if (n < 60 || n % 60 !== 0) return `${n} min`;
  const hours = n / 60;
  return hours === 1 ? "1 hour" : `${hours} hours`;
}

/** A number's words in a menu. */
export function count(rule: string, n: number): string {
  return rule === "noticeLimits.waitMinutes" ? minutes(n) : `${n}`;
}

function amount(value: JSONValue | undefined): number | undefined {
  if (value && typeof value === "object" && !Array.isArray(value) && typeof value.amount === "number") return value.amount;
  return undefined;
}

/** Whether value is looser than cap by the rule's order (FR-004), so a menu dims it. */
export function isLooser(row: Row, value: JSONValue, cap: JSONValue | undefined): boolean {
  if (cap === undefined || cap === null) return false;
  switch (row.kind.kind) {
    case "choice": {
      const v = row.kind.order.indexOf(String(value));
      const c = row.kind.order.indexOf(String(cap));
      return v >= 0 && c >= 0 && v < c;
    }
    case "money": {
      const v = amount(value), c = amount(cap);
      return v !== undefined && c !== undefined && v > c;
    }
    case "tokens":
      return typeof value === "number" && typeof cap === "number" && value > cap;
    case "count":
      if (typeof value !== "number" || typeof cap !== "number") return false;
      return row.kind.higherIsTighter ? value < cap : value > cap;
    case "toggle":
      return value === true && cap === false;
    case "list":
      return false;
  }
}

/** Your own value is kept while a layer above caps it (FR-006). */
export function yoursIsKept(rule: EffectiveRule): boolean {
  return rule.layers.some((l) => l.layer.kind === "you" && l.kept);
}

type Loose = Record<string, unknown>;

/** The value a layer's rules set for a row; undefined when unset. */
export function ruleValue(rules: PolicyRules, rule: string): JSONValue | undefined {
  const [group, key] = rule.split(".");
  const top = (rules as Loose)[group!];
  if (key === undefined) return top as JSONValue | undefined;
  return top && typeof top === "object" ? ((top as Loose)[key] as JSONValue | undefined) : undefined;
}

/** rules with one row set to value, or unset with undefined. An emptied group is dropped, so the layer keeps only
 * the rules it sets (FR-014). On is the archive switch's default: only Off is kept. */
export function setting(rules: PolicyRules, rule: string, value: JSONValue | undefined): PolicyRules {
  const next: Loose = structuredClone(rules) as Loose;
  const [group, key] = rule.split(".");
  if (rule === "archiveMyChats" && value === true) value = undefined;
  if (key === undefined) {
    if (value === undefined) delete next[group!];
    else next[group!] = value;
  } else {
    const inner: Loose = { ...((next[group!] as Loose | undefined) ?? {}) };
    if (value === undefined) delete inner[key];
    else inner[key] = value;
    if (Object.keys(inner).length === 0) delete next[group!];
    else next[group!] = inner;
  }
  return next as PolicyRules;
}

/** What a money field's text sets: null for text that is no amount, so nothing is saved; undefined for an empty
 * field, which is no limit, never a zero. */
export function moneyValue(text: string): JSONValue | undefined | null {
  const t = text.trim().replace("$", "");
  if (t === "") return undefined;
  const v = Number(t);
  return Number.isFinite(v) && v >= 0 ? { amount: v, currency: "USD" } : null;
}

/** What a token field's text sets, on the same terms; grouping ("2,000,000") is taken out. */
export function tokensValue(text: string): JSONValue | undefined | null {
  const digits = text.replace(/[\s,_.]/g, "");
  if (digits === "") return undefined;
  const v = Number(digits);
  return Number.isInteger(v) && v >= 1 ? v : null;
}

// Rules signed on another Mac (#3230): policy/yours's untrusted copy, which policy/settleUntrustedYours signs or sets
// aside, as the person chooses.

export const untrustedTitle = "Your rules from another Mac don’t apply";
export const signAgain = "Sign with This Mac’s Key";
export const setAside = "Don’t Use Them";
export const untrustedNone = "It sets no rules.";

/** Why the rules stopped applying, and what signing does. */
export function untrustedLine(copy: UntrustedYourPolicy): string {
  const day = fromWireDate(copy.changed).toLocaleDateString(undefined, { dateStyle: "medium" });
  return `These rules were signed on another Mac on ${day}, with a key this Mac doesn’t have, so they stopped applying here. Check them. Then sign them with this Mac’s key to use them again.`;
}

/** One of its rules: "Per day: $40.00 a day". */
export function untrustedRule(line: PolicyRuleLine): string {
  return `${line.title}: ${line.words}`;
}

// A folder's layer, opened from the banner's list in the same pane (#2957, T057, research R13): the web page has no
// Folder Settings, so Agents ▸ Policy edits it, as the window's Folder Settings ▸ Policy does (FR-022).

export const backToYours = "‹ Your policy";
export const openFolder = "Open a folder…";
export const folderWaits = "A change to .agents/policy.json waits for your OK. The last approved rules apply until then.";

/** A folder's name: the last part of its path, from a path or a file URL. */
export function folderName(folder: string): string {
  const parts = absolutePath(folder).split("/");
  return parts[parts.length - 1] || folder;
}

/** The person's effective value of a rule, as a folder that sets nothing gets it: the words of the layer above the
 * folder whose value is the cap, or what applies when no layer sets it. */
export function yoursWords(row: Row, rule: EffectiveRule | undefined): string {
  if (!rule || rule.cap === undefined) return row.unset;
  const cap = JSON.stringify(rule.cap);
  return rule.layers.find((l) => l.layer.kind !== "folder" && l.value !== undefined && JSON.stringify(l.value) === cap)?.words ?? row.unset;
}

/** A folder row's "not set" choice (FR-022): Same as yours, with your value. */
export function sameAsYoursLine(row: Row, rule: EffectiveRule | undefined): string {
  return `${sameAsYours} (${yoursWords(row, rule)})`;
}

/** The folder's value is looser than yours, so yours applies (spec US3 scenario 6). */
export function folderIsKept(rule: EffectiveRule): boolean {
  return rule.layers.some((l) => l.layer.kind === "folder" && l.kept);
}

/** Where Agents ▸ Policy is in Settings' route item: your layer, or a folder's (#/settings/settings/policy:<folder>). */
export function policyItem(folder?: string): string {
  return folder === undefined ? "policy" : `policy:${folder}`;
}

/** Organisation Policy's route item in Settings. */
export const organisationItem = "organisationPolicy";

/** The folder a route item opens in Agents ▸ Policy; undefined for your own layer. */
export function policyFolderOf(item: string | undefined): string | undefined {
  return item?.startsWith("policy:") ? item.slice("policy:".length) || undefined : undefined;
}

// The Stopped by a policy card (#2957, FR-025, T060, frame E), as Shared/UI/Chat/PolicyStopCard.swift draws it.

export const stoppedTitle = "Stopped by a policy";

/** A refusal's rule by its row's title, "Budget" for the organisation's whole budget across machines, and any other
 * by its name. */
export function stopRuleTitle(rule: string | undefined): string | undefined {
  if (rule === undefined) return undefined;
  if (rule === "budgets") return "Budget";
  return rows.find((r) => r.rule === rule)?.title ?? rule;
}

/** How a line names a layer, as the machine's capLine does: "Your policy" for the person's. */
export function layerName(layer: PolicyLayerRef): string {
  return layer.kind === "you" ? "Your policy" : layer.name;
}

/** The card's line under the rule: "<layer>: <value>", when the value says more than the words do. */
export function stopLayerLine(refusal: PolicyRefusal): string | undefined {
  if (!refusal.layer || refusal.value === undefined || refusal.value === refusal.words) return undefined;
  return `${layerName(refusal.layer)}: ${refusal.value}`;
}

/** What the card offers: Change for a layer the person can edit, Open Spending for an organisation budget (with Ask
 * for More beside it, canAskForMore), See Organisation Policy for another organisation rule. */
export type StopAction =
  | { kind: "yours"; label: string }
  | { kind: "folder"; label: string; folder: string }
  | { kind: "spending"; label: string }
  | { kind: "organisation"; label: string };

export function stopAction(refusal: PolicyRefusal): StopAction {
  const layer = refusal.layer;
  if (layer?.kind === "you") return { kind: "yours", label: `Change in ${groupTitle} ▸ ${title}` };
  // The web page has no Folder Settings (research R13): the folder's layer opens in Agents ▸ Policy.
  if (layer?.kind === "folder" && layer.folder !== undefined) {
    return { kind: "folder", label: `Change in ${layer.name}’s ${title}`, folder: layer.folder };
  }
  if (refusal.reason === "budget") return { kind: "spending", label: "Open Spending" };
  return { kind: "organisation", label: `See ${organisationTitle}` };
}

// Ask for More (#3262, spec 998 FR-019): at the organisation's budget, the card asks an admin to raise it for today.

export const askForMoreTitle = "Ask for More";
export const askForMoreHelp = "Ask your organisation's admins to raise today's budget. They answer on Console ▸ Requests.";

/** Whether the card offers Ask for More: the organisation's budget stopped the agent. */
export function canAskForMore(refusal: PolicyRefusal): boolean {
  return refusal.reason === "budget" && stopAction(refusal).kind === "spending";
}

/** The card's line once asked, by where the request stands. */
export function askedWords(r: BudgetRequest): string {
  const by = r.decidedBy ? ` by ${r.decidedBy}` : "";
  switch (r.state) {
    case "raised": return `Raised${r.daily !== undefined ? ` to ${dollars(r.daily)}` : ""} for today${by}. Send again to go on.`;
    case "refused": return `Refused for today${by}.`;
    default: return "Asked. An admin can raise today's budget.";
  }
}

/** Why Ask for More did not go: a control plane older than the ask says so. */
export function askRefusal(error: unknown): string | undefined {
  const code = (error as { code?: number } | null)?.code;
  return code === -32601 ? "This control plane cannot take the request yet. Update it, or ask an admin another way." : undefined;
}

// A waiting change to a folder's .agents/policy.json (#2957, T058, frame D): the guarded-change card's words.

/** The card's three answers: Allow keeps the change, Keep <was> undoes it, Show Change reviews it. */
export function policyChangeButtons(policy: GuardedChangePolicy): { allow: string; undo: string; review: string } {
  return { allow: "Allow", undo: policy.was ? `Keep ${policy.was}` : "Keep Old Rules", review: "Show Change" };
}
