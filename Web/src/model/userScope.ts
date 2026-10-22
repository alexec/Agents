// You ▸ On Every Machine's words (#1760, spec 736 US4), as the window and the Remote have them
// (UserScopeWords in Packages/AgentsKit): the secrets and settings the control plane keeps for
// the person and sends to each machine of theirs.
import type { SecretsLeft, UserSecretRow, UserSettings, UserSettingsPartName } from "../protocol/generated";

export const title = "On Every Machine";

/** The parts, in the order the section shows them. */
export const parts: UserSettingsPartName[] = ["mcpServers", "agentConfig", "runtimes", "costLimits", "resources"];

const titles: Record<UserSettingsPartName, string> = {
  mcpServers: "MCP servers",
  agentConfig: "Agent configuration",
  runtimes: "Agent runtime choices",
  costLimits: "Cost limits",
  resources: "Resources",
};

const details: Record<UserSettingsPartName, string> = {
  mcpServers: "Your own servers in ~/.agents/mcp.json.",
  agentConfig: "Your instructions, personas and one-file skills in ~/.agents.",
  runtimes: "Each runtime's sandbox and permission choices. Sign-ins stay on each machine.",
  costLimits: "The most an agent and a day may spend.",
  resources: "What agents take turns with, such as build.",
};

export function partTitle(part: UserSettingsPartName): string { return titles[part]; }
export function partDetail(part: UserSettingsPartName): string { return details[part]; }

/** Whether a part is the same on every machine. */
export function follows(settings: UserSettings | null, part: UserSettingsPartName): boolean {
  const value = settings?.[part];
  return value !== undefined && value !== null;
}

export function partState(settings: UserSettings | null, part: UserSettingsPartName): string {
  return follows(settings, part) ? "The same on every machine of yours." : "Each machine keeps its own.";
}

export const stop = "Each Machine Its Own";
export const addSecret = "Add a Secret…";
export const secretsFoot = "A secret goes only to your own machines, into ~/.agents-secrets/secrets.env. "
  + "Write ${NAME} for it in an MCP server's env or headers. Nobody can read it back, you included: to change it, replace it.";
export const noSealing = "This control plane has no key to seal secrets with, so it keeps none. "
  + "Its operator starts it with a key file or AGENTS_CONTROL_KMS.";
export const partsFoot = "A setting here is the same on every machine of yours, and on each new one as it joins. "
  + "Change it in its own pane on any of your Macs: the change goes to every machine of yours. "
  + "Choose on the Mac which of its settings are the same on every machine of yours.";
export const nameHint = "Capital letters, digits and _, such as GITHUB_TOKEN.";

/** A secret's row: where it is. */
export function machines(row: Pick<UserSecretRow, "machines">): string {
  const n = row.machines.length;
  return n === 0 ? "On no machine yet" : n === 1 ? "On 1 machine" : `On ${n} machines`;
}

/** Under a secret that was on a machine since removed (FR-026). */
export function leftOn(row: Pick<UserSecretRow, "leftOn">): string | null {
  const left = row.leftOn ?? [];
  if (left.length === 0) return null;
  return `It was on ${left.map((l) => l.name).join(", ")}, which was removed. Change it where it was issued, then replace it here.`;
}

/** When a machine of yours went with secrets on it (control/secretsLeft). */
export function secretsLeft(left: SecretsLeft): string {
  const one = left.secrets.length === 1;
  return `${left.name} was removed with ${one ? "this secret" : "these secrets"} on it: ${left.secrets.join(", ")}. `
    + `Change ${one ? "it" : "them"} where ${one ? "it was" : "they were"} issued.`;
}

/** A secret's name as the person types it. */
export function isSecretName(name: string): boolean {
  return /^[A-Z_][A-Z0-9_]{0,63}$/.test(name);
}
