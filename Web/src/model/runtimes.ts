// The order runtimes are listed in, as RuntimeCatalog.sortedByName (AgentsKitCore) has it (#154):
// alphabetical by the name shown, case-insensitive and as the person's language would, the id
// breaking a tie. A host on an older build still answers in its catalog's order.
import type { AccountProfile, Agent, AllowanceReading, AllowanceState, OrgPolicy, PolicySetBy, RuntimeAllowances, RuntimeAllowancesRow, RuntimeStatus } from "../protocol/generated";
import { line, runtimeName, tokens } from "./orgPolicy";
import { fromWireDate } from "../protocol/dates";
import { fromOrganisation, noPlanLimit, requires, routeMissing, routeRemoved } from "./orgAccounts";
import { hasTurnInFlight } from "./promptWords";
import { autoID } from "./levels";
import { switchTime } from "./switchNote";

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
 * turn now, out of how many are installed, and the available ones nearly used up (#3956). Installed
 * is found on the host, whether or not it can start; one that is not there, or is still being
 * installed, was never in. Undefined until a host has listed its runtimes: not yet known is not none.
 * `allowancesOf` is the allowances of the host a runtime is read from.
 */
export function runtimeTally(runtimes: readonly RuntimeStatus[],
  allowancesOf: (runtimeID: string) => RuntimeAllowances | undefined = () => undefined): RuntimeTally | undefined {
  if (runtimes.length === 0) return undefined;
  const installed = runtimes.filter((r) => "available" in r.availability || "needsSignIn" in r.availability || "failed" in r.availability);
  const low = installed.filter((r) => "available" in r.availability).flatMap((r): LowAllowance[] => {
    const allowances = allowancesOf(r.runtime.id);
    const state = allowances && ownRow(allowances.rows, r.runtime.id)?.state;
    if (!allowances || !state) return [];
    const at = fromWireDate(allowances.at);
    const reading = state.reading;
    if (reading && (reading.resetsAt === undefined || fromWireDate(reading.resetsAt).getTime() > at.getTime())) {
      const used = reading.spent ? 1 : reading.used;
      if (used !== undefined && used >= lowUsed) return [{ runtimeID: r.runtime.id, left: 1 - used }];
      if (used === undefined && reading.nearlySpent) return [{ runtimeID: r.runtime.id }];
    }
    // On course to run out before the week resets (#5000): less than 10% left wins.
    const pace = allowancePace(state, at);
    const week = pace?.current;
    if (!pace?.onCourseToRunOut || !week) return [];
    const used = week.spent ? 1 : week.used!;
    if (used >= lowUsed) return [{ runtimeID: r.runtime.id, left: 1 - used }];
    return [{ runtimeID: r.runtime.id, left: 1 - used, ...(pace.runsOutAt ? { runsOutAt: pace.runsOutAt } : {}),
      resetsAt: fromWireDate(week.resetsAt!) }];
  });
  return { working: installed.filter((r) => "available" in r.availability && !r.isOut).length, total: installed.length, low };
}

export interface RuntimeTally { working: number; total: number; low: LowAllowance[] }

/**
 * One runtime with little allowance left: `left` from 0 to 1, none when it said nearly used up and no amount.
 * `runsOutAt` and `resetsAt` when the week is on course to run out before it resets (#5000).
 */
export interface LowAllowance { runtimeID: string; left?: number; runsOutAt?: Date; resetsAt?: Date }

/** Used from here on is low: less than 10% left (Alex, #3956), not the Runtimes bar's 80%. RuntimeTally.lowUsed. */
export const lowUsed = 0.9;

/**
 * The grey line under Status ▸ Runtimes (#3956), RuntimeTally.lowWords: `Claude: 8% left`, `Claude: nearly used up`,
 * `Claude: runs out Fri at this pace` (#5000), or for two or more `Claude, Codex: low allowance`. Undefined when nothing is low, or none work: then the red wins.
 */
export function lowWords(tally: RuntimeTally | undefined, now: Date = new Date()): string | undefined {
  const one = tally?.low[0];
  if (!tally || tally.working === 0 || !one) return undefined;
  if (tally.low.length > 1) return `${tally.low.map((l) => runtimeName(l.runtimeID)).join(", ")}: low allowance`;
  if (one.runsOutAt) return `${runtimeName(one.runtimeID)}: runs out ${runsOutWords(one.runsOutAt, now)} at this pace`;
  return one.left === undefined ? `${runtimeName(one.runtimeID)}: nearly used up` : `${runtimeName(one.runtimeID)}: ${Math.round(one.left * 100)}% left`;
}

/**
 * The title's and a screen reader's words (#5000), RuntimeTally.lowDetail: for one on course to run out, with the
 * reset, `Claude runs out Fri at this pace; it resets Sun 09:00. 55% left.`; else the grey line.
 */
export function lowDetail(tally: RuntimeTally | undefined, now: Date = new Date()): string | undefined {
  const one = tally?.low[0];
  if (!tally || tally.working === 0 || tally.low.length !== 1 || !one?.runsOutAt) return lowWords(tally, now);
  let words = `${runtimeName(one.runtimeID)} runs out ${runsOutWords(one.runsOutAt, now)} at this pace`;
  if (one.resetsAt) words += `; it resets ${switchTime(one.resetsAt, now)}`;
  words += ".";
  if (one.left !== undefined) words += ` ${Math.round(one.left * 100)}% left.`;
  return words;
}

/** When a week runs out at its pace (#5000), PoolWords.runsOut: the day, "Fri", or the time, "15:00", under a day away. */
export function runsOutWords(date: Date, now: Date): string {
  if (date.getTime() - now.getTime() < 86_400_000) return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  return date.toLocaleDateString([], { weekday: "short" });
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

// Signing a server's Claude or Codex in from the page (#3349): RuntimeSignInWords on the Mac.

/** Whether a runtime's row offers Sign In… on its machine: Claude or Codex on a server, not signed in there. */
export function offersMachineSignIn(status: RuntimeStatus): boolean {
  return status.signIn !== undefined && !status.signIn.signedIn && !status.signIn.relayed;
}

/** The line under a server's Claude or Codex: whether it is signed in on the machine. */
export function machineSignInLine(status: RuntimeStatus): string | undefined {
  const signIn = status.signIn;
  if (!signIn) return undefined;
  if (signIn.signedIn) return "Signed in on this machine";
  return signIn.relayed ? "Uses the Mac’s sign-in" : "Not signed in on this machine";
}

/** A runtime's line on a machine's page (#3629): installed or not, its version (#3674), and signed in where the machine says.
 * RuntimeStatus.machineLine on the Mac. Accounts and allowances are the person's, so they are not said here. */
export function machineRuntimeLine(status: RuntimeStatus): string {
  const a = status.availability;
  const signIn = status.signIn;
  const installed = status.version ? `Installed ${status.version}` : "Installed";
  const line = "available" in a
    ? !signIn ? installed
      : signIn.signedIn ? `${installed} · signed in`
      : signIn.relayed ? `${installed} · uses the Mac’s sign-in` : `${installed} · not signed in`
    : "needsSignIn" in a ? `${installed} · not signed in`
    : "missing" in a ? "Not installed"
    : "failed" in a ? `Can’t be used: ${a.failed.reason}`
    : "installing" in a ? (a.installing.progress ? `Installing: ${a.installing.progress}` : "Installing…")
    : `Install failed: ${a.installFailed.reason}`;
  return status.outdated ? `${line} · an update is out` : line;
}

/** Whether it is on the machine, so the machine's page lists it (#3743): not missing, and not a failed install.
 * RuntimeStatus.isInstalled. */
export function isInstalled(status: RuntimeStatus): boolean {
  return !("missing" in status.availability) && !("installFailed" in status.availability);
}

/** Whether a runtime's row on its machine's page offers Update (#4174): the app carries a newer copy it can install, and none is going. */
export function offersUpdate(status: RuntimeStatus): boolean {
  return status.outdated && status.runtime.install != null && !("installing" in status.availability);
}

/**
 * One runtime on Status ▸ Runtimes (#3631): shown once, not once per machine. Its accounts,
 * allowances and Reaches the Model By are read on its home machine: the Mac when it lists the
 * runtime (accounts are added and signed in there, #2257), else the first machine that does. Then
 * a line per machine, the Mac first and the others by name, as Machines lists them (#3626).
 */
export interface SetupRuntime {
  status: RuntimeStatus;
  home: string;
  machines: { host: string; status?: RuntimeStatus }[];
}

/**
 * The oldest read on a runtimes page (#5145), in ms since 1970: each machine's last runtimes/list (an
 * offline one's kept from before it went) and the allowances'. Undefined before any was read.
 */
export function runtimesReadAt(lists: readonly (readonly RuntimeStatus[])[], allowances: readonly RuntimeAllowances[] = []): number | undefined {
  const times = [...lists.flat().map((s) => s.checkedAt), ...allowances.map((a) => a.at)].map((at) => fromWireDate(at).getTime());
  return times.length ? Math.min(...times) : undefined;
}

export function setupRuntimes(hosts: readonly { id: string; name: string }[], macID: string,
                              lists: Readonly<Record<string, readonly RuntimeStatus[] | undefined>>): SetupRuntime[] {
  const ordered = [...hosts].sort((a, b) => Number(b.id === macID) - Number(a.id === macID) || a.name.localeCompare(b.name));
  const out = new Map<string, SetupRuntime>();
  for (const host of ordered) {
    for (const status of lists[host.id] ?? []) {
      if (!out.has(status.runtime.id)) out.set(status.runtime.id, { status, home: host.id, machines: [] });
    }
  }
  for (const each of out.values()) {
    each.machines = ordered.map((host) => {
      const status = lists[host.id]?.find((s) => s.runtime.id === each.status.runtime.id);
      return status ? { host: host.id, status } : { host: host.id };
    });
  }
  return sortedRuntimes([...out.values()].map((r) => r.status)).map((s) => out.get(s.runtime.id)!);
}

/** A part of a runtime's machines line: the words, then the machines they are true of. */
export interface MachinesPart { words: string; hosts: string[] }

/**
 * A runtime's machines on Status ▸ Runtimes in one line (#3744), RuntimeMachinesSummary on the Mac: "On all 3
 * machines", or "On This Mac · Not on build-box". `inUse` is installed, or being installed, somewhere.
 */
export function machinesSummary(machines: readonly { host: string; status?: RuntimeStatus }[],
                                online: (host: string) => boolean): { parts: MachinesPart[]; inUse: boolean } {
  const order = ["On", "Not signed in on", "Can’t be used on", "Installing on", "Not on", "Offline:", "Not known yet on"] as const;
  const kind = (status: RuntimeStatus | undefined, host: string): (typeof order)[number] => {
    if (!status) return online(host) ? "Not known yet on" : "Offline:";
    const a = status.availability;
    if ("available" in a) return status.signIn && !status.signIn.signedIn && !status.signIn.relayed ? "Not signed in on" : "On";
    if ("needsSignIn" in a) return "Not signed in on";
    if ("missing" in a) return "Not on";
    if ("installing" in a) return "Installing on";
    return "Can’t be used on";
  };
  const groups = order.map((words) => ({ words, hosts: machines.filter((m) => kind(m.status, m.host) === words).map((m) => m.host) }));
  const parts: MachinesPart[] = machines.length > 1 && groups[0]!.hosts.length === machines.length
    ? [{ words: `On all ${machines.length} machines`, hosts: [] }]
    : groups.filter((g) => g.hosts.length > 0).map((g) => ({ words: g.words, hosts: g.hosts }));
  const outdated = machines.filter((m) => m.status?.outdated).map((m) => m.host);
  if (outdated.length) parts.push({ words: "An update is out on", hosts: outdated });
  return { parts, inUse: machines.some((m) => m.status && !("missing" in m.status.availability)) };
}

/** The machines line as plain words: "On This Mac, devbox · Not on build-box". */
export function machinesWords(parts: readonly MachinesPart[], name: (host: string) => string): string {
  return parts.map((p) => [p.words, p.hosts.map(name).join(", ")].filter(Boolean).join(" ")).join(" · ");
}

/** The words of the sheet that signs a runtime in on a machine with no browser. */
export const machineSignInWords = {
  title: (runtime: string, machine: string) => `Sign In to ${runtime} on ${machine}`,
  asking: (runtime: string) => `Asking ${runtime} for a link…`,
  openLink: "Open this link, and sign in to your account:",
  open: "Open Link",
  copyLink: "Copy Link",
  pasteCode: "Then paste the code the page gives:",
  typeCode: "Then type this code on the page:",
  codexNote: "If OpenAI does not take the code, turn on device code sign-in in ChatGPT’s security settings.",
  codeLabel: "Code",
  useKey: "Use an API Key Instead",
  useAccount: "Sign In to an Account Instead",
  keyLabel: "API key",
  keyNote: (runtimeID: string) => runtimeID === "claude"
    ? "An Anthropic API key, or a token that claude setup-token made on another computer. It is kept on the machine."
    : "An OpenAI API key. Codex keeps it on the machine.",
  signIn: "Sign In",
  done: "Done",
  signingIn: "Signing in…",
} as const;

/**
 * Under the Runtimes page (#3382): where a runtime is installed and signed in. With a Mac, its
 * Settings ▸ Agent Runtimes and Runtimes; with none, the machines' own rows on this page.
 */
export function runtimesHint(hasMac: boolean): string {
  return hasMac ? "Install a runtime on the Mac, in Settings ▸ Agent Runtimes. Sign it in on the Mac, in Status."
    : "Runtimes run on your machines: add one with Add a Machine… in the sidebar’s Machines menu. "
      + "Sign Claude or Codex in on a machine with Sign In… in its row.";
}

/** Where an added account is signed in: the Mac's Runtimes page (#2255). */
export const signInOnTheMac = "Sign it in on the Mac, in Status.";

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

const week = 7 * 86400;

/**
 * A plan's week against an even pace, and its past weeks (#3438), as AllowancePace
 * (AgentsKitCore) reads them from the weekly readings the daemon keeps: Claude's `seven_day` or
 * Grok's `weekly` window first, then the newest window kept. Null when it kept no week.
 */
export function allowancePace(state: AllowanceState | undefined, now: Date):
  { current?: AllowanceReading; past: AllowanceReading[]; evenLeft?: number; verdict?: "faster" | "even" | "slower";
    runsOutAt?: Date; onCourseToRunOut?: boolean } | null {
  const weeks = state?.weeks ?? [];
  const windows = weeks.map((w) => w.window).filter((w): w is string => !!w);
  const window = ["seven_day", "weekly"].find((w) => windows.includes(w)) ?? windows[windows.length - 1];
  if (!window) return null;
  const isCurrent = (r: AllowanceReading) => fromWireDate(r.resetsAt!).getTime() > now.getTime();
  const mine = weeks.filter((w) => w.window === window && w.resetsAt != null && (w.spent || w.used != null));
  const current = mine.filter(isCurrent).pop();
  const past = mine.filter((w) => !isCurrent(w));
  if (!current && !past.length) return null;
  if (!current) return { past };
  const evenLeft = Math.min(Math.max((current.resetsAt! - current.at) / week, 0), 1);
  const left = current.spent ? 0 : 1 - current.used!;
  const verdict = left < evenLeft - 0.05 ? "faster" : left > evenLeft + 0.05 ? "slower" : "even";
  // On course to run out before it resets (#5000), as AllowancePace.runsOutAt and onCourseToRunOut: at this pace
  // all used at least 12 hours before the reset, with a day gone and 10% used.
  const used = 1 - left;
  const elapsed = current.at - (current.resetsAt! - week);
  if (used <= 0 || elapsed <= 0) return { current, past, evenLeft, verdict, onCourseToRunOut: false };
  const runsOutAt = new Date(fromWireDate(current.at).getTime() + (1 - used) * elapsed / used * 1000);
  const onCourseToRunOut = elapsed >= paceStart && used >= paceUsed
    && runsOutAt.getTime() <= fromWireDate(current.resetsAt!).getTime() - paceMargin * 1000;
  return { current, past, evenLeft, verdict, runsOutAt, onCourseToRunOut };
}

/** AllowancePace.paceStart, paceUsed and paceMargin (#5000): a day gone, 10% used, 12 hours before the reset. */
const paceStart = 86400;
const paceUsed = 0.1;
const paceMargin = 12 * 3600;

const percent = (fraction: number) => `${Math.round(fraction * 100)}%`;

/** "3 days to go", "1 day to go", "5 hours to go", "Under an hour to go", to the nearest day or hour, as PoolWords.toGo. */
function toGo(seconds: number): string {
  const days = Math.round(seconds / 86400);
  if (days > 1) return `${days} days to go`;
  if (seconds >= 86400) return "1 day to go";
  const hours = Math.round(seconds / 3600);
  if (hours > 1) return `${hours} hours to go`;
  if (hours === 1) return "1 hour to go";
  return "Under an hour to go";
}

/**
 * The pace line under the reading, PoolWords.pace: "3 days to go · used faster than an even pace
 * (43% left)", with "28% left this week · " first when the reading line says another window.
 */
export function allowancePaceLine(state: AllowanceState | undefined, now: Date): string | null {
  const pace = allowancePace(state, now);
  const current = pace?.current;
  if (!pace || !current || pace.evenLeft == null) return null;
  const parts: string[] = [];
  const reading = state?.reading;
  const sameWeek = reading && reading.window === current.window && reading.resetsAt === current.resetsAt
    && fromWireDate(reading.resetsAt!).getTime() > now.getTime();
  const left = current.spent ? 0 : 1 - current.used!;
  if (!sameWeek) parts.push(left <= 0 ? "None left this week" : `${percent(left)} left this week`);
  parts.push(toGo((fromWireDate(current.resetsAt!).getTime() - now.getTime()) / 1000));
  parts.push(pace.verdict === "even" ? "on an even pace" : `used ${pace.verdict} than an even pace (${percent(pace.evenLeft)} left)`);
  if (pace.onCourseToRunOut && pace.runsOutAt) parts.push(`runs out ${runsOutWords(pace.runsOutAt, now)} at this pace`);
  return parts.join(" · ");
}

/** The past weeks in words, PoolWords.pastWeeks: "Past weeks: 62%, 71%, 90% used". */
export function pastWeeksLine(state: AllowanceState | undefined, now: Date): string | null {
  const past = allowancePace(state, now)?.past ?? [];
  if (!past.length) return null;
  return `Past weeks: ${past.map((w) => percent(w.spent ? 1 : w.used!)).join(", ")} used`;
}
