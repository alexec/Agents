// The order runtimes are listed in, as RuntimeCatalog.sortedByName (AgentsKitCore) has it (#154):
// alphabetical by the name shown, case-insensitive and as the person's language would, the id
// breaking a tie. A host on an older build still answers in its catalog's order.
import type { AccountProfile, Agent, AllowanceState, OrgPolicy, PolicySetBy, RuntimeAllowancesRow, RuntimeStatus } from "../protocol/generated";
import { line, runtimeName, tokens } from "./orgPolicy";
import { fromWireDate } from "../protocol/dates";
import { fromOrganisation, noPlanLimit, requires, routeMissing, routeRemoved } from "./orgAccounts";
import { hasTurnInFlight } from "./promptWords";
import { autoID } from "./levels";

export function byName(a: { name: string; id: string }, b: { name: string; id: string }): number {
  return a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true })
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

export function sortedRuntimes(runtimes: RuntimeStatus[]): RuntimeStatus[] {
  return [...runtimes].sort((a, b) => byName(a.runtime, b.runtime));
}

/**
 * The runtime a new session opens on: a kept Auto while it can start, then the most recently used
 * runtime that can start, then the start form's kept choice, then the first available runtime
 * (#264). Auto, once picked, stays (#3017): a session started on a named runtime (a persona, a
 * continued session, another client) does not move the form off it.
 */
export function newSessionRuntime(lastUsed: string | undefined, kept: string | undefined, available: readonly string[]): string | undefined {
  if (kept === autoID && available.includes(autoID)) return autoID;
  if (lastUsed !== undefined && available.includes(lastUsed)) return lastUsed;
  if (kept !== undefined && available.includes(kept)) return kept;
  return available[0];
}

/**
 * The runtime a new-session form stays on (#291). The one it opened with, until the person
 * picks another or that one can no longer start. A later listing does not move it, so another
 * agent's activity does not discard the draft and start a second runtime.
 */
export function formRuntime(opened: string | undefined, picked: string | undefined,
                            startable: readonly string[], lastUsed: string | undefined, kept: string | undefined): string | undefined {
  if (picked !== undefined && startable.includes(picked)) return picked;
  if (opened !== undefined && startable.includes(opened)) return opened;
  return newSessionRuntime(lastUsed, kept, startable);
}

/**
 * The window's empty folder list (FolderListView): nothing on this Mac can start an agent.
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

/** The name the account picker gives a runtime's own sign-in (#840, #999), AccountProfile.defaultName. */
export const defaultAccountName = "Your Own Sign-In";

/** A runtime's own allowance row: the first that is not an added account's (#840). */
export function ownRow(rows: readonly RuntimeAllowancesRow[], runtimeID: string): RuntimeAllowancesRow | undefined {
  return rows.find((row) => row.credentialKey.split(":", 1)[0] === runtimeID && row.accountID === undefined);
}

/** The rows of the accounts of a runtime: the ones added, in the order they were added (#840), then the organisation's (#999). */
export function accountRows(rows: readonly RuntimeAllowancesRow[], runtimeID: string): RuntimeAllowancesRow[] {
  return rows.filter((row) => row.credentialKey.split(":", 1)[0] === runtimeID && row.accountID !== undefined);
}

/** An added account's row is named for the runtime and the account: "Claude · Work" (Row.title). */
export function rowTitle(row: RuntimeAllowancesRow, runtimeName: string): string {
  return row.accountName === undefined ? runtimeName : `${runtimeName} · ${row.accountName}`;
}

/**
 * A started session's runtime, and the account it runs on when that is not the runtime's own
 * sign-in, as the Runtimes rows name it: "Claude · Work" (#2259; PromptWords.runtimeName(_:accounts:)).
 */
export function sessionRuntimeName(runtimeName: string, runtimeID: string, accountID: string | undefined,
  profiles: readonly AccountProfile[]): string {
  if (accountID === undefined || accountID === ownSignInID) return runtimeName;
  const account = profiles.find((a) => a.id === accountID && a.runtimeID === runtimeID);
  return account ? `${runtimeName} · ${account.name}` : runtimeName;
}

/** An organisation's account (#999), AccountProfile.isOrganisation: not one the person added. */
export function isOrgAccount(account: AccountProfile): boolean {
  const reach = account.reach ?? {};
  return account.source === "organisation" || "orgKey" in reach || "gateway" in reach;
}

/** An org account's allowance row (#999): its id is org:<route id>. */
export function isOrgRow(row: RuntimeAllowancesRow): boolean {
  return row.accountID?.startsWith("org:") === true;
}

/** The words under an account's name, AccountProfile.state: From your organisation for an org account (FR-023). */
export function accountState(account: AccountProfile): string {
  if (isOrgAccount(account)) return fromOrganisation;
  if (!account.signedIn) return "Not signed in";
  return account.signedInAs === undefined ? "Signed in" : `Signed in as ${account.signedInAs}`;
}

// The words of an added account (#840) on every client: AccountWords on the Mac and the Remote.

/** Where an added account is signed in: the Mac's Runtimes page (#2255). */
export const signInOnTheMac = "Sign it in on the Mac, in Runtimes.";

/** What Remove does, under its question: how many sessions it stops, and that it can't be undone (#2264). */
export function removeMessage(stopping: number, place: string): string {
  const stops = stopping === 0 ? "Nothing is running on it."
    : `This stops ${stopping} session${stopping === 1 ? "" : "s"} mid-conversation.`;
  return `${stops} Its sign-in is deleted from ${place}. This can’t be undone.`;
}

/** The sessions an added account is running, which removing it stops: AppModel.agentsHolding(account:). */
export function agentsHolding(agents: readonly Agent[], account: AccountProfile): Agent[] {
  return agents.filter((a) => a.runtimeID === account.runtimeID && a.accountID === account.id && hasTurnInFlight(a));
}

/** A time on the Runtimes page, such as 14:05. */
export const runtimeTime = (wire: number) => fromWireDate(wire as never).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

/** An allowance's state, as the Runtimes page says it. */
export function allowanceLine(state: AllowanceState): string {
  if ("available" in state.status) return "Available";
  if ("rateLimited" in state.status) return `Rate limited · trying again at ${runtimeTime(state.status.rateLimited.until)}`;
  const out = state.status.out;
  return out.until ? `Out · reset ${runtimeTime(out.until)}${out.retryAfter ? ` · checking after ${runtimeTime(out.retryAfter)}` : ""}`
    : `Out since ${runtimeTime(state.since)}${out.retryAfter ? ` · checking after ${runtimeTime(out.retryAfter)}` : ""}`;
}

/**
 * The line under a choice of account when a session starts (#2265), AccountWords.choiceNote: why
 * it cannot be used, or that its allowance is out, else who it is. `account` undefined is the
 * runtime's own sign-in; `row` is its allowance row.
 */
export function choiceNote(account: AccountProfile | undefined, row: RuntimeAllowancesRow | undefined, now: Date): string | undefined {
  if (account && !account.signedIn && !isOrgAccount(account)) return accountState(account);
  const fallback = account && isOrgAccount(account) ? accountState(account) : account?.signedInAs;
  if (!row) return fallback;
  if (row.unusable) return `Not usable: ${row.unusable}`;
  if (!("out" in row.state.status)) return fallback;
  return isOrgRow(row) ? orgAllowanceLine(row.state, row.tokensToday, now, runtimeTime, allowanceLine) : allowanceLine(row.state);
}

// What a member sees of an org account (#999, slice 3): OrgAccountMemberWords on the Mac and the Remote.

export const reachesTheModelBy = "Reaches the Model By";
export const reachesFoot = "New sessions use this account. You can still choose another when you start one.";
export const continueInNew = "Continue in New";

/**
 * An org account's allowance line (D12, FR-025), OrgAccountWords.allowance: no plan reading, so
 * "Organisation · No plan limit · 12,000 tokens today", or "Out until 14:05" after a rate limit.
 * Any other state is `other`, the page's own line. `time` says a wire date as the page does.
 */
export function orgAllowanceLine(state: AllowanceState, tokensToday: number | undefined, now: Date,
                                 time: (wire: number) => string, other: (state: AllowanceState) => string): string {
  let head: string;
  const s = state.status;
  if ("available" in s) head = noPlanLimit;
  else if ("rateLimited" in s) head = fromWireDate(s.rateLimited.until).getTime() <= now.getTime() ? noPlanLimit : `Out until ${time(s.rateLimited.until)}`;
  else if (s.out.until !== undefined) head = `Out until ${time(s.out.until)}`;
  else head = other(state);
  return tokensToday === undefined ? head : `${head} · ${tokens(tokensToday)} today`;
}

/** After a cost on an org account: the runtime's own price (FR-025). "list price, as Claude reports it". */
export function listPrice(runtimeID: string): string {
  return `list price, as ${runtimeName(runtimeID)} reports it`;
}

/** A cost figure, and on an org account whose price it is: Agent.priced. */
export function priced(agent: Pick<Agent, "accountID" | "runtimeID">, figure: string): string {
  return agent.accountID?.startsWith("org:") ? `${figure} · ${listPrice(agent.runtimeID)}` : figure;
}

/** The id runtimes/setDefaultAccount names a runtime's own sign-in by, AccountProfile.ownSignInID. */
export const ownSignInID = "default";

/**
 * A runtime's accounts as the account picker and Reaches the Model By list them (#840, #999),
 * AccountChoices on the Mac and the Remote. A choice is kept as an account id: undefined is the
 * runtime's account for new sessions, "default" its own sign-in, any other id that account.
 */
export function accountChoices(runtimeID: string, profiles: readonly AccountProfile[], policy?: OrgPolicy | null) {
  const accounts = profiles.filter((a) => a.runtimeID === runtimeID);
  const defaultAccount = accounts.find((a) => a.isDefault === true);
  const account = (chosen: string | undefined): AccountProfile | undefined => {
    if (chosen === undefined) return defaultAccount;
    if (chosen === ownSignInID) return undefined;
    return accounts.find((a) => a.id === chosen) ?? defaultAccount;
  };
  const ownChoice = defaultAccount === undefined ? undefined : ownSignInID;
  const reach = policy?.runtimes?.[runtimeID]?.reach;
  let ownSetBy: PolicySetBy | undefined;
  if (reach && !reach.includes("signIn")) {
    const route = (defaultAccount ?? accounts.find((a) => isOrgAccount(a) && !a.setBy))?.name;
    ownSetBy = { by: "organisation", rule: `runtimes.${runtimeID}.reach`, words: route ? requires(runtimeID, route) : routeMissing };
  }
  return {
    runtimeID, accounts, defaultAccount, ownChoice, ownSetBy, account,
    /** Whether the picker shows: an account beside the own sign-in, an org one included (FR-023). */
    shows: accounts.length > 0,
    name: (chosen: string | undefined) => account(chosen)?.name ?? defaultAccountName,
    /** What a start sends for a choice. */
    sent: (chosen: string | undefined): string | undefined => {
      if (chosen === undefined) return undefined;
      if (chosen === ownSignInID) return ownChoice;
      return accounts.some((a) => a.id === chosen) ? chosen : undefined;
    },
    /** Why a session on accountID can no longer reach the model, for the strip with Continue in New. */
    moveReason: (accountID: string | undefined, loaded: boolean): string | undefined => {
      if (!loaded) return undefined;
      if (accountID === undefined) return ownSetBy?.words;
      const found = accounts.find((a) => a.id === accountID);
      if (found) return found.setBy?.words;
      return accountID.startsWith("org:") ? routeRemoved("this way to the model") : undefined;
    },
  };
}
