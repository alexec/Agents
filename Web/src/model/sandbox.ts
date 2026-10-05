// A runtime's command sandbox, as a new session chooses it (064, #257): SandboxCatalog's choices
// and states and SandboxWords' menu words (Runtimes/SandboxCatalog.swift, SandboxWords.swift),
// ported by hand and held to Fixtures/web/sandbox. A runtime the catalog has no route for has no
// choice: its state is said, with why.
import type { SandboxChoice, SandboxState } from "../protocol/generated";

type Route = "choices" | "offOnly" | "codexMode" | { fixed: SandboxState };

/** Each runtime's route, as SandboxCatalog.entries measured them, and its sentence where it lacks one. */
const catalog: Record<string, { route: Route; why?: string }> = {
  claude: { route: "choices" },
  codex: { route: "codexMode" },
  grok: { route: "choices" },
  gemini: { route: "offOnly", why: "Gemini’s own sandbox cannot start when the app runs it, so On is not offered." },
  cursor: { route: { fixed: "runtimeControlled" }, why: "Cursor’s own sandbox setting decides. The app cannot change it." },
  copilot: { route: { fixed: "runtimeControlled" }, why: "Copilot’s own sandbox setting decides. The app cannot change it yet." },
  antigravity: { route: { fixed: "none" },
    why: "Antigravity sandboxes commands only when a business account’s admin turns Sandbox mode on." },
  opencode: { route: { fixed: "none" },
    why: "OpenCode has no command sandbox. It asks before running commands unless set to Always-approve." },
};

/** The choices a person may make, `runtime` first; none for a runtime with no route. */
export function sandboxChoices(runtimeID: string): SandboxChoice[] {
  const route = catalog[runtimeID]?.route;
  if (route === "choices" || route === "codexMode") return ["runtime", "on", "off"];
  if (route === "offOnly") return ["runtime", "off"];
  return [];
}

/** Why a runtime has no choice, or lacks one. */
export function sandboxWhy(runtimeID: string): string | undefined {
  return catalog[runtimeID]?.why;
}

/** The state a resolved choice gives; Codex's from its mode, whatever was asked. */
export function sandboxState(runtimeID: string, choice: SandboxChoice, codexMode?: string): SandboxState {
  const route = catalog[runtimeID]?.route;
  if (!route) return "runtimeControlled";
  if (typeof route === "object") return route.fixed;
  if (route === "codexMode") return codexMode === "agent-full-access" ? "off" : "on";
  return choice === "on" ? "on" : choice === "off" ? "off" : "runtimeControlled";
}

export function sandboxChoiceWords(choice: SandboxChoice, runtimeID: string): string {
  const codex = runtimeID === "codex";
  if (choice === "runtime") return "As configured by runtime";
  if (choice === "on") return codex ? "On (Ask or Approve for me)" : "On";
  return codex ? "Off (Full access)" : "Off";
}

/** One agent's menu, where no choice follows the runtime's default. */
export function sandboxOverrideWords(choice: SandboxChoice | undefined, runtimeDefault: SandboxChoice, runtimeID: string): string {
  return choice ? sandboxChoiceWords(choice, runtimeID) : `Use runtime default (${sandboxChoiceWords(runtimeDefault, runtimeID)})`;
}

export function sandboxStateWords(state: SandboxState): string {
  switch (state) {
    case "on": return "Sandbox on";
    case "off": return "Sandbox off";
    case "runtimeControlled": return "Sandbox: runtime controlled";
    default: return "No sandbox";
  }
}

export function sandboxExplanation(choice: SandboxChoice, runtimeID: string, name: string): string {
  const codex = runtimeID === "codex";
  if (choice === "runtime") {
    return codex ? "The mode decides: Full access has no sandbox, the other modes do." : `${name}’s own settings decide. The app adds nothing.`;
  }
  if (choice === "on") {
    if (codex) return "Commands can write only in the project and cannot reach the network. The mode still decides when Codex asks.";
    if (runtimeID === "claude") {
      return "Commands can write only in the project, and Claude asks before they reach a new website. Its permission mode is a separate choice.";
    }
    return `Commands can write only in the project, its temporary folders and ${name}’s own folder. Its permission mode is a separate choice.`;
  }
  return codex
    ? "Full access: commands run with your own access, and Codex stops asking for approval."
    : `Commands run with your own access. ${name} still asks as its permission mode says.`;
}

/** SandboxWords.startWithout: a new session's way past a sandbox that will not start. */
export const startWithout = "Start without sandbox";

/** SandboxWords.cardTitle. */
export function sandboxCardTitle(name: string): string {
  return `${name}’s sandbox could not start`;
}
