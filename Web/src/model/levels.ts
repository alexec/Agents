// The words every runtime shares (#2658), as LevelWords says them: one set for each field,
// so a pill under the prompt says its value only. Pinned by Fixtures/web/levels/words.json.
import type { AutoField, AutoMapping, AutoMappings, AutoMark, AutoSkip, ClientPermissionMode, Levels, ModelLevel, PermissionLevel, SandboxChoice } from "../protocol/generated";

export const autoID = "auto";
export const autoWords = "Auto";

export const modelLevels: ModelLevel[] = ["fast", "balanced", "smart"];
export const permissionLevels: PermissionLevel[] = ["plan", "ask", "approveForMe", "bypassPermissions"];
export const requestModes: ClientPermissionMode[] = ["default", "alwaysApprove"];
export const sandboxValues: SandboxChoice[] = ["runtime", "on", "off"];
export const autoFields: AutoField[] = ["model", "permission", "permissionRequests", "sandbox"];

export const fieldWords: Record<AutoField, string> = {
  model: "Model", permission: "Permission mode", permissionRequests: "Permission requests", sandbox: "Sandbox",
};

const words: Record<AutoField, Record<string, string>> = {
  model: { fast: "Fast", balanced: "Balanced", smart: "Smart" },
  permission: { plan: "Plan", ask: "Ask", approveForMe: "Approve for me", bypassPermissions: "Bypass Permissions" },
  permissionRequests: { default: "Request cards", alwaysApprove: "Yes to all" },
  sandbox: { runtime: "Default sandbox", on: "Runtime sandbox", off: "No sandbox" },
};

const meanings: Record<AutoField, Record<string, string>> = {
  model: {
    fast: "The runtime’s smallest and quickest model that can do the work.",
    balanced: "Its usual model.",
    smart: "Its most capable model.",
  },
  permission: {
    plan: "Reads and plans; cannot change files or run commands that change things.",
    ask: "Asks before it changes things.",
    approveForMe: "Does not ask for normal changes in its folder.",
    bypassPermissions: "Never asks, even for a change outside its folder.",
  },
  permissionRequests: {
    default: "Each permission request is a card for you.",
    alwaysApprove: "The app says yes to each permission request.",
  },
  sandbox: {
    runtime: "The runtime’s own settings decide.",
    on: "The app turns the runtime’s sandbox on.",
    off: "Commands run with your own access.",
  },
};

export const levelsOf = (field: AutoField): string[] => Object.keys(words[field]);
export const levelWords = (field: AutoField, level: string): string => words[field][level] ?? level;
export const levelMeaning = (field: AutoField, level: string): string => meanings[field][level] ?? "";

export const customWords = "Custom";
export const followsSettings = "follows Settings";
export const ownWords = (runtimeName: string): string => `⋯ ${runtimeName}’s own`;
export const onRuntime = (value: string, native: string, runtimeName: string): string => `${value}: ${native} on ${runtimeName}`;
export const picksWords = (runtimeName: string | undefined): string => runtimeName ? `Picks ${runtimeName} now` : "No runtime can start now";
export const noneIncluded = "No runtime included";
export const autoHeader = (runtimeName: string): string => `${autoWords} · ${runtimeName}`;
export const noRuntimeWords = (skipped: AutoSkip[], name: (id: string) => string): string =>
  skipped.length ? skipped.map((s) => `${name(s.runtimeID)}: ${s.reason}`).join("; ") : "No runtime can take this session.";
export const continueOn = (runtimeName: string): string => `Continue on ${runtimeName}`;

export const markWords: Record<AutoMark, string> = {
  autoMapped: "auto-mapped", nearestSafer: "nearest safer", yours: "yours", notPossible: "Not possible", dropped: "no longer offered",
};

/** A pill's words for a field of an agent: its value, or Custom. */
export function levelPill(levels: Levels | undefined, field: "model" | "permission"): string {
  const v = levels?.[field];
  return v ? levelWords(field, v) : customWords;
}

/** The words in workflow, persona and start_session files. */
export function fileWord(field: AutoField, level: string): string {
  const special: Record<string, string> = {
    "permission:approveForMe": "approve-for-me", "permission:bypassPermissions": "bypass-permissions", "permissionRequests:default": "request-cards",
    "permissionRequests:alwaysApprove": "yes-to-all", "sandbox:runtime": "default", "sandbox:on": "runtime", "sandbox:off": "none",
  };
  return special[`${field}:${level}`] ?? level;
}

/** The cell for a runtime, field and value, from auto/mappings. */
export function cellOf(mappings: AutoMappings | undefined, runtimeID: string, field: AutoField, level: string): AutoMapping | undefined {
  return mappings?.cells.find((c) => c.runtimeID === runtimeID && c.field === field && c.level === level);
}

/** The runtimes the cells are for, in the person's order. */
export function mappedRuntimes(mappings: AutoMappings | undefined): string[] {
  const out: string[] = [];
  for (const c of mappings?.cells ?? []) if (!out.includes(c.runtimeID)) out.push(c.runtimeID);
  return out;
}

/** Which value of a field a runtime's own settings are: the first cell whose every option
 *  they have, Fast and Smart before Balanced, or undefined (Custom). */
export function matchLevel(mappings: AutoMappings | undefined, runtimeID: string, field: "model" | "permission",
  value: (optionID: string) => unknown): string | undefined {
  const order = field === "model" ? ["fast", "smart", "balanced"] : levelsOf(field);
  for (const level of order) {
    const cell = cellOf(mappings, runtimeID, field, level);
    const options = cell?.native?.options;
    if (!cell || cell.mark === "notPossible" || !options || !Object.keys(options).length) continue;
    if (Object.entries(options).every(([id, v]) => JSON.stringify(value(id)) === JSON.stringify(v))) return level;
  }
  return undefined;
}
