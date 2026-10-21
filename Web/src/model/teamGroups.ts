// Settings ▸ Groups (#1761, spec 736 FR-027, FR-028): the same words as GroupWords in
// Packages/AgentsKit. A group is everyone, or the people named; it owns workspace providers, and
// only its people see them and start machines from them. A provider with no group is the admins'.
import type { CapReached, Group, PersonRow, ProviderSummary, SpendCaps } from "../protocol/generated";

export const title = "Groups";
export const adminsOnly = "Admins only";

/** "Everyone", "Sam, Kim", or "No one". */
export function members(group: Group, people: readonly PersonRow[]): string {
  if (group.everyone) return "Everyone";
  if (group.members.length === 0) return "No one";
  return group.members.map((id) => people.find((p) => p.id === id)?.name ?? "Someone removed").join(", ");
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
    ? "A group is everyone, or the people you name. Give a workspace provider to a group, and only its people see it and start machines from it. A provider with no group is for admins only."
    : "The groups you are in. Their workspace providers are the ones you can start machines from.";
}

export const removeTitle = (group: Group) => `Remove ${group.name}?`;
export const removeMessage = "Its people keep their machines. A provider must go to another group first.";

// A bot in Settings ▸ People (#1761): the same words as BotWords in Packages/AgentsKit.
export const botWords = {
  make: "Make a Bot…",
  addMachine: "Add a Machine…",
  setCap: "Group and Cap…",
  foot: "A bot runs the team’s workflows: a workflow whose runs-on: names it runs on its machines, once per trigger. Nobody can start, message or answer its agents; an admin can stop a run. Its spend counts against its own cap and its group’s.",
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

/** A cap typed in: dollars, or undefined for no cap. A bad number is no cap too. */
export function parseCap(text: string): number | undefined {
  const usd = Number(text.trim().replace("$", ""));
  return text.trim() !== "" && Number.isFinite(usd) && usd > 0 ? usd : undefined;
}
