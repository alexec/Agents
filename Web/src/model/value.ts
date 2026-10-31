// Reports ▸ Value (#2351), as ReportValueWords has it on the window: what the work cost and what it
// delivered, from reports/value. The control plane adds it up from the machines' lineage nodes.
import type { LineageCost, LineageNode, ReportValue, ReportValueRow } from "../protocol/generated";
import { money } from "./limits";
import { timeWords } from "./time";
import { tokenWords } from "./usage";

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** The cost by currency, "$4.00", or the tokens when nothing had a price. */
export function costWords(c: LineageCost): string {
  const priced = Object.entries(c.cost).filter(([, v]) => v > 0).sort(([a], [b]) => a.localeCompare(b));
  if (priced.length > 0) return priced.map(([currency, v]) => money(v, currency)).join(" + ");
  return `${tokenWords(c.inputTokens + c.outputTokens)} tokens`;
}

export const spent = (c: LineageCost) => Object.values(c.cost).some((v) => v > 0) || c.inputTokens + c.outputTokens > 0;

/** An issue's, a PR's, a milestone's or a release's name without its tracker: "alexec/agents#12",
 * "ENG-4", "alexec/agents milestone 15", "alexec/agents release v0.14.0" (#3023). */
export function nodeName(n: LineageNode): string {
  const [, id = n.ref] = /^[a-z][a-z0-9-]*:(.*)$/.exec(n.ref) ?? [];
  const milestone = /^(.*)\/milestone\/(.+)$/.exec(id);
  if (milestone) return `${milestone[1]} milestone ${milestone[2]}`;
  const release = /^(.*)\/release\/(.+)$/.exec(id);
  return release ? `${release[1]} release ${release[2]}` : id;
}

/** Where a GitHub issue, PR, milestone or release is, as ReportValueWords.url has it; nothing for a
 * tracker whose address the ref does not say. */
export function nodeUrl(n: LineageNode): string | undefined {
  const github = "https://github.com/";
  if (!n.ref.startsWith("github:")) return undefined;
  const id = n.ref.slice("github:".length);
  const milestone = /^(.*?)\/milestone\/(.*)$/.exec(id);
  if (milestone) return `${github}${milestone[1]}/milestone/${milestone[2]}`;
  const release = /^(.*?)\/release\/(.*)$/.exec(id);
  if (release) return `${github}${release[1]}/releases/tag/${release[2]}`;
  const issue = /^([^#]*)#(\d+)$/.exec(id);
  return issue ? `${github}${issue[1]}/issues/${issue[2]}` : undefined;
}

/** The figures at the top: "$12.40 on issues and pull requests · 3 merged · $4.13 a merged pull request". */
export function valueHeadline(v: ReportValue): string {
  const parts = [`${costWords(v.total)} on issues and pull requests`, `${v.prsMerged} merged`];
  const per = Object.entries(v.perMergedPR).sort(([a], [b]) => a.localeCompare(b));
  for (const [currency, amount] of per) parts.push(`${money(amount, currency)} a merged pull request`);
  return parts.join(" · ");
}

/** "$3.00 wasted: 1 closed without a merge, 1 revert · 2 failed CI rounds", or that nothing was wasted. */
export function wasteLine(w: { waste: LineageCost; prsClosed: number; prsReverted: number; failedChecks: number }): string {
  const parts: string[] = [];
  const why: string[] = [];
  if (w.prsClosed > 0) why.push(`${w.prsClosed} closed without a merge`);
  if (w.prsReverted > 0) why.push(plural(w.prsReverted, "revert", "reverts"));
  parts.push(why.length > 0 ? `${costWords(w.waste)} wasted: ${why.join(", ")}` : "Nothing wasted");
  if (w.failedChecks > 0) parts.push(plural(w.failedChecks, "failed CI round", "failed CI rounds"));
  return parts.join(" · ");
}

/** "19h from the first work on an issue to its merge (the median)". */
export function leadLine(v: ReportValue): string | undefined {
  return v.leadTimeSeconds === undefined ? undefined : `${timeWords(v.leadTimeSeconds)} from the first work on an issue to its merge (the median)`;
}

/** The turns that had no issue or pull request, or nothing when there were none. */
export function unlinkedLine(v: ReportValue): string | undefined {
  return spent(v.unlinked) ? `${costWords(v.unlinked)} on turns with no issue or pull request` : undefined;
}

/** An issue's or a milestone's figures: "$10.00 · 1 merged, 1 closed · $3.00 wasted · 2 failed CI rounds · 19h to merge". */
export function rowLine(r: ReportValueRow): string {
  const parts = [costWords(r.total)];
  const ends: string[] = [];
  if (r.prsMerged > 0) ends.push(`${r.prsMerged} merged`);
  if (r.prsClosed > 0) ends.push(`${r.prsClosed} closed`);
  if (r.prsReverted > 0) ends.push(`${r.prsReverted} reverted`);
  parts.push(ends.length > 0 ? ends.join(", ") : "Not merged yet");
  if (spent(r.waste)) parts.push(`${costWords(r.waste)} wasted`);
  if (r.failedChecks > 0) parts.push(plural(r.failedChecks, "failed CI round", "failed CI rounds"));
  if (r.leadTimeSeconds !== undefined) parts.push(`${timeWords(r.leadTimeSeconds)} to merge`);
  return parts.join(" · ");
}

export const noValue = "No work on issues or pull requests in this time. A session works on one when it has a label such as #12 or P#34, or opens a pull request on its branch.";
export const valueNote = "An issue’s cost is its own and its pull requests’, from every machine. A pull request closed without a merge, and a merged revert, is waste. A node counts in the range when it last changed in it, with all of its cost. The lead time is from the first work on an issue to its last pull request merged.";
export const noValueHere = "This control plane does not add up the value of the work yet. Update it to see it.";
