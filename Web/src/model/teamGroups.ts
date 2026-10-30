// Settings ▸ Groups (#1761, spec 736 FR-027, FR-028): the same words as GroupWords in
// Packages/AgentsKit. A group is everyone, or the people named; it owns machine providers, and
// only its people see them and start machines from them. A provider with no group is the admins'.
import type { CapReached, Group, PersonRow, ProviderSummary, SpendCaps } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export const title = "Groups";
export const adminsOnly = "Admins only";

/** "Everyone", "Sam, Kim", or "No one". */
export function members(group: Group, people: readonly PersonRow[]): string {
  if (group.everyone) return "Everyone";
  if (group.members.length === 0) return "No one";
  return group.members.map((id) => people.find((p) => p.id === id)?.name ?? "Someone removed").join(", ");
}

/** The bots in a group (#2132), which a bot names itself: "review-bot, nightly-bot", or "None". */
export function groupBots(group: Group, people: readonly PersonRow[]): string {
  const names = people.filter((p) => p.kind === "bot" && p.group === group.id).map((p) => p.name);
  return names.length === 0 ? "None" : names.join(", ");
}

/** "DigitalOcean, Docker", or null with none. */
export function providersOf(group: Group, all: readonly ProviderSummary[]): string | null {
  const names = all.filter((p) => p.group === group.id).map((p) => p.name);
  return names.length > 0 ? names.join(", ") : null;
}

/** Who a provider is for: its group's name, or the admins alone. */
export function providerGroup(provider: ProviderSummary, groups: readonly Group[]): string {
  if (!provider.group) return adminsOnly;
  return groups.find((g) => g.id === provider.group)?.name ?? "A group not shown to you";
}

/** "For Platform": a provider's line, said only when there are groups. */
export function providerLine(provider: ProviderSummary, groups: readonly Group[]): string | null {
  if (groups.length === 0 && !provider.group) return null;
  if (!provider.group) return "For admins only";
  return `For ${providerGroup(provider, groups)}`;
}

/** Whether the caller may start machines from it; a control plane before groups lets everyone. */
export function usable(provider: ProviderSummary): boolean {
  return provider.mayUse ?? true;
}

/** Why New Machine is not there for a provider the caller sees but may not use. */
export function mayNotUse(provider: ProviderSummary, groups: readonly Group[]): string {
  if (!provider.group) return `Give ${provider.name} to a group to start machines from it.`;
  const name = groups.find((g) => g.id === provider.group)?.name ?? "its group";
  return `Only ${name} can start machines from ${provider.name}.`;
}

export function foot(admin: boolean): string {
  return admin
    ? "A group is everyone, or the people you name. Give a machine provider to a group, and only its people see it and start machines from it. A provider with no group is for admins only."
    : "The groups you are in. Their machine providers are the ones you can start machines from.";
}

export const removeTitle = (group: Group) => `Remove ${group.name}?`;
export const removeMessage = "Its people keep their machines. A provider must go to another group first.";

// A bot in Settings ▸ Bots (#1761, #2132): the same words as BotWords in Packages/AgentsKit.
export const botWords = {
  title: "Bots",
  empty: "No bots yet. A bot runs workflows as its own user, in one group, with a daily cap.",
  make: "Make a Bot…",
  addMachine: "Add a Machine…",
  setCap: "Group and Cap…",
  foot: "A bot runs the team’s workflows: a workflow whose runs-on: names it runs on its machines, once per trigger. Nobody can start, message or answer its agents; an admin can stop a run in Workflows ▸ Team Workflows, on the web page. Its spend counts against its own cap and its group’s.",
  machineFoot: "Run this on the machine for the bot. It joins as the bot’s machine; the code works once, for 10 minutes.",
};

/** "$3.20", "$50". */
export function dollars(usd: number): string {
  return usd === Math.round(usd) ? `$${usd}` : `$${usd.toFixed(2)}`;
}

/** "$50 a day", or "No cap". */
export function capWords(caps: SpendCaps | undefined): string {
  return caps?.dailyUSD && caps.dailyUSD > 0 ? `${dollars(caps.dailyUSD)} a day` : "No cap";
}

/** "In Platform · $50 a day · $3.20 today". */
export function botLine(bot: PersonRow, groups: readonly Group[]): string {
  const group = groups.find((g) => g.id === bot.group)?.name ?? "a group not shown to you";
  const parts = [`In ${group}`, capWords(bot.caps)];
  if (bot.spentTodayUSD !== undefined) parts.push(`${dollars(bot.spentTodayUSD)} today`);
  return parts.join(" · ");
}

/** The notice an admin is shown when a bot stopped at a cap. */
export function capReachedWords(reached: CapReached): string {
  const whose = reached.group ? `${reached.group}’s cap` : "its cap";
  return `${reached.name} stopped at ${whose}: ${dollars(reached.spentUSD)} of ${dollars(reached.capUSD)} today. It starts work again at midnight UTC.`;
}

/** A group's daily cap and its bots' spend today together (#2074), as GroupWords.capLine: "$50 a day · $12 today". */
export function groupCapLine(group: Group, people: readonly PersonRow[]): string {
  const spent = people.filter((p) => p.kind === "bot" && p.group === group.id && p.spentTodayUSD !== undefined)
    .map((p) => p.spentTodayUSD ?? 0);
  const parts = [capWords(group.caps)];
  // To the cent, so $3.20 and $8.80 make $12.
  if (spent.length > 0) parts.push(`${dollars(Math.round(spent.reduce((a, b) => a + b, 0) * 100) / 100)} today`);
  return parts.join(" · ");
}

export const groupCapFoot = "Its bots together stop starting work at it, until midnight UTC.";

/** control/capReached: this bot's notice, in place of any it had (#2073). */
export function addCap(reached: CapReached, notices: readonly CapReached[]): CapReached[] {
  return [...notices.filter((n) => n.user !== reached.user), reached];
}

/** The notices left once an admin puts one away with OK (#2198), as PeopleState.dismissCap in Swift. */
export function dropCap(reached: Pick<CapReached, "user">, notices: readonly CapReached[]): CapReached[] {
  return notices.filter((n) => n.user !== reached.user);
}

/**
 * The cap notices still true (#2073), as CapNotices.open in Swift: before their until, and while the cap each
 * names is the one the bot, or the bot's group, has now. With no people list yet, only the time is weighed.
 */
export function openCaps(notices: readonly CapReached[], people: readonly PersonRow[] | null, groups: readonly Group[],
  now: number = Date.now()): CapReached[] {
  return notices.filter((notice) => {
    if (fromWireDate(notice.until).getTime() <= now) return false;
    if (!people) return true;
    // A bot removed has no cap to change.
    const bot = people.find((p) => p.id === notice.user);
    if (!bot) return false;
    if (!notice.group) return bot.caps?.dailyUSD === notice.capUSD;
    // Its group's cap: changed, or the bot moved to another group.
    const group = groups.find((g) => g.name === notice.group);
    return !!group && bot.group === group.id && group.caps?.dailyUSD === notice.capUSD;
  });
}

/** A daily cap as typed in (#2066): no cap, dollars, or the sentence that says why it is refused. */
export type CapEntry = { kind: "none" } | { kind: "dollars"; usd: number } | { kind: "refused"; problem: string };

export const capNotDollars = "Type the daily cap in dollars, such as 50 or $1,000, or leave it empty for no cap.";
export const capNotAboveZero = "A daily cap is more than $0. Leave it empty for no cap.";

/**
 * Reads a cap typed in, as `BotWords.readCap` does. Empty or "none" is no cap; "50", "$1,000", "50 USD" and
 * "$50 a day" are dollars. Any other text is refused, never saved as no cap.
 */
export function readCap(text: string): CapEntry {
  let words = text.trim().toLowerCase();
  if (["", "none", "no cap", "no"].includes(words)) return { kind: "none" };
  const strip = (ends: string[], suffix: boolean) => {
    const end = ends.find((e) => (suffix ? words.endsWith(e) : words.startsWith(e)));
    if (end) words = (suffix ? words.slice(0, -end.length) : words.slice(end.length)).trim();
  };
  strip(["a day", "per day", "/day", "each day", "daily"], true);
  strip(["usd", "dollars", "dollar"], true);
  strip(["us$", "usd", "$"], false);
  if (!/^(\d{1,3}(,\d{3})+(\.\d+)?|\d+(\.\d+)?|\.\d+)$/.test(words)) return { kind: "refused", problem: capNotDollars };
  const usd = Number(words.replaceAll(",", ""));
  if (!Number.isFinite(usd)) return { kind: "refused", problem: capNotDollars };
  return usd > 0 ? { kind: "dollars", usd } : { kind: "refused", problem: capNotAboveZero };
}
