// Status ▸ Secrets and Status ▸ Accounts (#4161, specs/secret-info §9), as the window's
// (Packages/AgentsKit, StatusSecretsWords): what happened last to each of the person's secrets and outside
// accounts, newest first, with a time ago. Status only: a press opens the item in Settings ▸ You.
import type { OutsideAccount, UserSecretRow } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export const statusSecretsWords = {
  secretsLead: "What happened to your secrets last, newest first. Only status here: change them in Settings ▸ You ▸ Secrets.",
  accountsLead: "What happened to your accounts last, newest first. Only status here: change them in Settings ▸ You ▸ Accounts.",
  editSecrets: "Edit in Settings ▸ You ▸ Secrets",
  editAccounts: "Edit in Settings ▸ You ▸ Accounts",
  noSecrets: "No secrets yet.",
  noAccounts: "No accounts yet.",
  notBackedUp: "Not backed up: only on one machine.",
  readLabel: "Last read:",
};

/** One line of a Status list. */
export interface StatusLine {
  id: string;
  /** The secret's name, or the account's service. */
  title: string;
  /** The account's address; null for a secret. */
  detail: string | null;
  /** ••••ab12, ••••, or for an account "no secret" or "not in Secrets". */
  hint: string;
  /** "Read", "Replaced", "GITLAB_TOKEN read"; null when nothing is known. */
  operation: string | null;
  /** Milliseconds, or null. */
  at: number | null;
  backedUp: boolean;
  /** Whether the last operation was a read: of the secret, or of the secret or card the account names. */
  isRead: boolean;
  /** The session that did the last operation, when one did. */
  agent: string | null;
}

/** How long a read stays recent for the sidebar row's grey line, in milliseconds. */
export const recentReadWindow = 4 * 3_600_000;

export function masked(hint: string | undefined): string {
  return "••••" + (hint ?? "");
}

const capital = (what: string) => what.charAt(0).toUpperCase() + what.slice(1);

/** A secret's or an account's operation in words: read, denied, added, replaced, removed, edited. */
export function operationWords(what: string): string {
  return capital(what);
}

/** An RFC 3339 time or a day (made is YYYY-MM-DD), in milliseconds, or null. */
function parsed(text: string | undefined): number | null {
  if (!text) return null;
  const ms = Date.parse(text);
  return Number.isNaN(ms) ? null : ms;
}

function newestFirst(a: StatusLine, b: StatusLine): number {
  if (a.at !== null && b.at !== null && a.at !== b.at) return b.at - a.at;
  if (a.at !== null && b.at === null) return -1;
  if (a.at === null && b.at !== null) return 1;
  return a.title.localeCompare(b.title);
}

/** The person's secrets, newest operation first; one with none goes by when it was added. */
export function secretLines(rows: readonly UserSecretRow[]): StatusLine[] {
  return rows.map((row): StatusLine => {
    const added = parsed(row.created);
    return {
      id: row.name, title: row.name, detail: null, hint: masked(row.hint),
      operation: row.lastOp ? operationWords(row.lastOp.what) : added !== null ? "Added" : null,
      at: row.lastOp ? fromWireDate(row.lastOp.at).getTime() : added,
      backedUp: row.backedUp !== false,
      isRead: row.lastOp?.what === "read",
      agent: row.lastOp?.agent ?? null,
    };
  }).sort(newestFirst);
}

/** The person's accounts, newest operation first: the newest of its own (made, edited, one a machine sent) and the last
 * operation of the secret and card it names, which says which ("GITLAB_TOKEN read"). Backed up when they are. */
export function accountLines(accounts: readonly OutsideAccount[], secrets: readonly UserSecretRow[]): StatusLine[] {
  const byName = new Map(secrets.map((s) => [s.name as string, s]));
  return accounts.map((a): StatusLine => {
    let newest: { words: string; at: number; read: boolean; agent: string | null } | null = null;
    const consider = (words: string, at: number | null, read = false, agent: string | null = null) => {
      if (at !== null && (newest === null || at > newest.at)) newest = { words, at, read, agent };
    };
    consider("Added", parsed(a.made));
    if (a.edited !== undefined) consider("Edited", fromWireDate(a.edited).getTime());
    if (a.lastOp) consider(operationWords(a.lastOp.what), fromWireDate(a.lastOp.at).getTime(), a.lastOp.what === "read", a.lastOp.agent ?? null);
    const named = [a.secret, a.card].filter((n): n is string => !!n);
    for (const name of named) {
      const op = byName.get(name)?.lastOp;
      if (op) consider(`${name} ${op.what}`, fromWireDate(op.at).getTime(), op.what === "read", op.agent ?? null);
    }
    const secret = a.secret || null;
    const row = secret ? byName.get(secret) : undefined;
    const hint = secret === null ? "no secret" : row ? masked(row.hint) : "not in Secrets";
    const found = newest as { words: string; at: number; read: boolean; agent: string | null } | null;
    return {
      id: `${a.service.toLowerCase()}#${(a.address ?? "").toLowerCase()}`, title: a.service, detail: a.address ?? null, hint,
      operation: found?.words ?? null, at: found?.at ?? null,
      backedUp: named.every((n) => byName.get(n)?.backedUp !== false),
      isRead: found?.read ?? false,
      agent: found?.agent ?? null,
    };
  }).sort(newestFirst);
}

/** The sidebar row's time: the newest operation on any line. */
export function newestAt(lines: readonly StatusLine[]): number | null {
  const times = lines.map((l) => l.at).filter((t): t is number => t !== null);
  return times.length ? Math.max(...times) : null;
}

/** The sidebar row's grey line: the name of the item read last (an account's address too) and the session that read
 * it, by agentTitle, only when the newest operation on any line is a read in the last 4 hours. Null otherwise. A session
 * the page does not know, or one with no title, is left out. */
export function recentRead(lines: readonly StatusLine[], now: number = Date.now(),
  agentTitle: (id: string) => string | undefined = () => undefined): string | null {
  const timed = lines.filter((l) => l.at !== null);
  if (!timed.length) return null;
  const newest = timed.reduce((a, b) => ((b.at as number) > (a.at as number) ? b : a));
  if (!newest.isRead || now - (newest.at as number) >= recentReadWindow) return null;
  const agent = newest.agent ? agentTitle(newest.agent) : undefined;
  return [newest.title, newest.detail, agent].filter((p): p is string => !!p).join(" · ");
}

/** "5 min ago", "2 h ago", "3 d ago", as the window's. */
export function shortAgo(at: number, now: number = Date.now()): string {
  const seconds = Math.max(0, (now - at) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86_400)} d ago`;
}

/** A row's line under its name: the address, the hint, then the operation. */
export function summary(line: StatusLine): string {
  return [line.detail, line.hint, line.operation].filter((p): p is string => !!p).join(" · ");
}
