// The user scope's words (#1760, #2157), as the window and the Remote have them (UserScopeWords
// in Packages/AgentsKit): the secrets and settings the control plane keeps for the person and
// sends to each machine of theirs. Machines ▸ Secrets, and the parts at the end of Machines.
import type { SecretsLeft, UserSecretRow } from "../protocol/generated";

export const secretsTitle = "Secrets";
export const addSecret = "Add a Secret…";
export const secretsFoot = "A secret goes only to your own machines, into ~/.agents-secrets/secrets.env. "
  + "Write ${NAME} for it in an MCP server's env or headers. Nobody can read it back, you included: to change it, replace it.";
export const noSealing = "This control plane has no key to seal secrets with, so it keeps none. "
  + "Its operator starts it with a key file or AGENTS_CONTROL_KMS.";
export const yoursOnEveryMachine = "Yours, on every machine";

/** Under yoursOnEveryMachine at the top of the ~/.agents editors (#2766): when the files last synced. */
export function agentConfigurationUpdated(updated: string | undefined, locale?: string): string {
  const date = updated ? new Date(updated) : null;
  if (!date || Number.isNaN(date.getTime())) return "Waiting for the first sync";
  return `Last synced ${date.toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" })}`;
}

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
