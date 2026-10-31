// A Mac's git access lent to a host (#1122): the ask on a host's row, the lends with Stop
// Lending, and the words, as GitLendWords and GitLendAsk in AgentsKitCore say them. The page
// is never the lending Mac, so it always names it.
import type { ControlMachine } from "../protocol/generated";

export interface GitLendAsk { host: string; hostName: string; server: string; from: string; lenderName: string }
export interface GitLend { host: string; hostName: string; server: string; from: string; lenderName: string }

export const askID = (host: string, server: string): string => `${host} ${server}`;

const nameOf = (rows: readonly ControlMachine[], id: string): string => rows.find((r) => r.id === id)?.name ?? id;

/** The first ask on `rows` not answered on this page yet. */
export function firstAsk(rows: readonly ControlMachine[], answered: ReadonlySet<string>): GitLendAsk | null {
  for (const row of rows) {
    for (const ask of row.gitAsks ?? []) {
      if (answered.has(askID(row.id, ask.server))) continue;
      return { host: row.id, hostName: row.name, server: ask.server, from: ask.from, lenderName: nameOf(rows, ask.from) };
    }
  }
  return null;
}

/** Every ask still waiting: one answered and no longer here may be asked again. */
export function waiting(rows: readonly ControlMachine[]): Set<string> {
  return new Set(rows.flatMap((row) => (row.gitAsks ?? []).map((ask) => askID(row.id, ask.server))));
}

/** Every lend on `rows`, host by host, git server by git server. */
export function lends(rows: readonly ControlMachine[]): GitLend[] {
  return rows.flatMap((row) => Object.entries(row.gitFrom ?? {}).flatMap(([server, from]) =>
    from ? [{ host: row.id, hostName: row.name, server, from, lenderName: nameOf(rows, from) }] : [])
    .sort((a, b) => a.server.localeCompare(b.server)));
}

export const gitLendWords = {
  title: (ask: GitLendAsk): string => `Let ${ask.hostName} use ${ask.lenderName}’s git access for ${ask.server}?`,
  message: (ask: GitLendAsk): string =>
    `Its git can then clone, pull and push on ${ask.server} as you, through ${ask.lenderName}, whenever ${ask.lenderName} is connected. `
    + `Nothing is kept on ${ask.hostName}. You can stop it in Settings ▸ Machines.`,
  footer: "A machine asks the first time its git needs a Mac’s git access for a server. Nothing is kept on the machine.",
};
