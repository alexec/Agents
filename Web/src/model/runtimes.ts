// The order runtimes are listed in, as RuntimeCatalog.sortedByName (AgentsKitCore) has it (#154):
// alphabetical by the name shown, case-insensitive and as the person's language would, the id
// breaking a tie. A host on an older build still answers in its catalog's order.
import type { RuntimeStatus } from "../protocol/generated";

/** The runtime a new agent gets when nothing else says: RuntimeCatalog.defaultRuntime. */
export const defaultRuntimeID = "claude";

export function byName(a: { name: string; id: string }, b: { name: string; id: string }): number {
  return a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true })
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

export function sortedRuntimes(runtimes: RuntimeStatus[]): RuntimeStatus[] {
  return [...runtimes].sort((a, b) => byName(a.runtime, b.runtime));
}

/**
 * The runtime a new session opens on, RuntimeCatalog.newSessionRuntime (#264), the one rule the
 * window, the Remote and the page follow: the start form's, while it can start; else the
 * default; else the first, in order.
 */
export function newSessionRuntime(kept: string | undefined, available: readonly string[]): string | undefined {
  if (kept !== undefined && available.includes(kept)) return kept;
  return available.includes(defaultRuntimeID) ? defaultRuntimeID : available[0];
}

/** RuntimeStatus.unavailableReason: why it cannot be started, in the runtime's own terms, or null. */
export function unavailableReason(status: RuntimeStatus): string | null {
  const a = status.availability;
  if ("available" in a) return null;
  if ("missing" in a) return `Looked for ${status.runtime.executable} in ${a.missing.lookedIn.slice(0, 4).join(", ")}…`;
  if ("needsSignIn" in a) return a.needsSignIn.fixCommand ? `Signed out. Run ${a.needsSignIn.fixCommand}.` : "Signed out.";
  if ("failed" in a) return a.failed.reason;
  if ("installing" in a) return a.installing.progress ? `Installing: ${a.installing.progress}` : "Installing…";
  return `${a.installFailed.reason} Install it from ${status.runtime.installPage}.`;
}

/**
 * A new session's runtime chooser in its runs, as the window's and the Remote's (065): those
 * that can take a turn now, those out of the pool (still pickable: a chat on one takes the
 * message, and it is the only way back to it), and those that cannot start, with why.
 */
export function runtimeRuns(runtimes: RuntimeStatus[]): { available: RuntimeStatus[]; out: RuntimeStatus[]; cannot: RuntimeStatus[] } {
  const startable = runtimes.filter((r) => "available" in r.availability);
  return {
    available: startable.filter((r) => !r.isOut),
    out: startable.filter((r) => r.isOut),
    cannot: runtimes.filter((r) => !("available" in r.availability)),
  };
}
