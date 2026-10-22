// The order runtimes are listed in, as RuntimeCatalog.sortedByName (AgentsKitCore) has it (#154):
// alphabetical by the name shown, case-insensitive and as the person's language would, the id
// breaking a tie. A host on an older build still answers in its catalog's order.
import type { AccountProfile, RuntimeAllowancesRow, RuntimeStatus } from "../protocol/generated";
import { line } from "./orgPolicy";

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

/**
 * The runtime a new-session form stays on (#291). The one it opened with, until the person
 * picks another or that one can no longer start. A later listing does not move it, so another
 * agent's activity does not discard the draft and start a second runtime.
 */
export function formRuntime(opened: string | undefined, picked: string | undefined,
                            startable: readonly string[], kept: string | undefined): string | undefined {
  if (picked !== undefined && startable.includes(picked)) return picked;
  if (opened !== undefined && startable.includes(opened)) return opened;
  return newSessionRuntime(kept, startable);
}

/**
 * The window's empty project list (ProjectListView): nothing on this Mac can start an agent.
 * Unknown until the host has listed its runtimes. An empty list counts: there is nothing to start.
 */
export function noAgentRuntime(runtimes: readonly RuntimeStatus[] | undefined): boolean {
  return runtimes !== undefined && !runtimes.some((r) => "available" in r.availability);
}

/**
 * The line under a runtime's name on that empty list (RuntimeInstallRow), and the install page
 * when the window would offer **Open install page**. A runtime the app itself can install has no
 * page here: **Install** stays on the Mac, in Settings ▸ Agent Runtimes. The download size the
 * window adds ("112 MB from Google") comes from the app bundle, which the page does not carry.
 */
export function emptyListRuntimeLine(status: RuntimeStatus): { line: string; failed: boolean; page?: string } {
  const a = status.availability;
  const page = status.runtime.installPage;
  if ("missing" in a) return { line: "Not on this Mac", failed: false, ...(status.runtime.install ? {} : { page }) };
  if ("installing" in a) return { line: a.installing.progress ? `${a.installing.progress}…` : "Starting…", failed: false };
  if ("installFailed" in a) return { line: a.installFailed.reason, failed: true, page };
  if ("available" in a) return { line: "", failed: false };
  return { line: unavailableReason(status) ?? "Can’t be used", failed: false };
}

/** RuntimeStatus.unavailableReason: why it cannot be started, in the runtime's own terms, or null. */
export function unavailableReason(status: RuntimeStatus): string | null {
  if (status.setBy) return line(status.setBy);
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
  // A runtime the organisation does not allow here cannot start: listed, dimmed, with why (#998).
  const startable = runtimes.filter((r) => "available" in r.availability && !r.setBy);
  return {
    available: startable.filter((r) => !r.isOut),
    out: startable.filter((r) => r.isOut),
    cannot: runtimes.filter((r) => !("available" in r.availability) || r.setBy),
  };
}

/**
 * The sidebar's Runtimes row (#379), RuntimeTally (AgentsKitCore): how many runtimes can start a
 * turn now, out of how many are installed. Installed is found on the host, whether or not it can
 * start; one that is not there, or is still being installed, was never in. Undefined until a host
 * has listed its runtimes: not yet known is not none.
 */
export function runtimeTally(runtimes: readonly RuntimeStatus[]): { working: number; total: number } | undefined {
  if (runtimes.length === 0) return undefined;
  const installed = runtimes.filter((r) => "available" in r.availability || "needsSignIn" in r.availability || "failed" in r.availability);
  return { working: installed.filter((r) => "available" in r.availability && !r.isOut).length, total: installed.length };
}

/** The name the account picker gives a runtime's own sign-in (#840), AccountProfile.defaultName. */
export const defaultAccountName = "Default account";

/** A runtime's own allowance row: the first that is not an added account's (#840). */
export function ownRow(rows: readonly RuntimeAllowancesRow[], runtimeID: string): RuntimeAllowancesRow | undefined {
  return rows.find((row) => row.credentialKey.split(":", 1)[0] === runtimeID && row.accountID === undefined);
}

/** The rows of the accounts added to a runtime, in the order they were added (#840). */
export function accountRows(rows: readonly RuntimeAllowancesRow[], runtimeID: string): RuntimeAllowancesRow[] {
  return rows.filter((row) => row.credentialKey.split(":", 1)[0] === runtimeID && row.accountID !== undefined);
}

/** An added account's row is named for the runtime and the account: "Claude · Work" (Row.title). */
export function rowTitle(row: RuntimeAllowancesRow, runtimeName: string): string {
  return row.accountName === undefined ? runtimeName : `${runtimeName} · ${row.accountName}`;
}

/** The words under an added account's name, AccountProfile.state. */
export function accountState(account: AccountProfile): string {
  if (!account.signedIn) return "Not signed in";
  return account.signedInAs === undefined ? "Signed in" : `Signed in as ${account.signedInAs}`;
}
