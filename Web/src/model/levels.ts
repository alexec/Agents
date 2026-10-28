// The words every runtime shares (#2658), as LevelWords says them: one set for each field,
// so a pill under the prompt says its value only. Pinned by Fixtures/web/levels/words.json.
import type { AutoField, AutoMark, AutoSkip, ClientPermissionMode, Levels, ModelLevel, PermissionLevel, SandboxChoice } from "../protocol/generated";

export const autoID = "auto";
export const autoWords = "Auto";

export const modelLevels: ModelLevel[] = ["fast", "balanced", "smart"];
export const permissionLevels: PermissionLevel[] = ["plan", "ask", "approveForMe"];
export const requestModes: ClientPermissionMode[] = ["default", "alwaysApprove"];
export const sandboxValues: SandboxChoice[] = ["runtime", "on", "off"];
export const autoFields: AutoField[] = ["model", "permission", "permissionRequests", "sandbox"];

export const fieldWords: Record<AutoField, string> = {
  model: "Model", permission: "Permission mode", permissionRequests: "Permission requests", sandbox: "Sandbox",
};

const words: Record<AutoField, Record<string, string>> = {
  model: { fast: "Fast", balanced: "Balanced", smart: "Smart" },
  permission: { plan: "Plan", ask: "Ask", approveForMe: "Approve for me" },
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
    "permission:approveForMe": "approve-for-me", "permissionRequests:default": "request-cards",
    "permissionRequests:alwaysApprove": "yes-to-all", "sandbox:runtime": "default", "sandbox:on": "runtime", "sandbox:off": "none",
  };
  return special[`${field}:${level}`] ?? level;
}
