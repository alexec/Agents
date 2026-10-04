// PoolWords.switchNote, whole (#252): a chat carried on with another runtime (052) says, as it
// happened, why, what settings went with it and whence, what was left out, and how it is paid
// for. Nothing switches since 065, but a chat that did before still says so.
import type { Payment, SwitchRecord } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

/** RuntimeCatalog's names, for a runtime the page may not be told about any more. */
const runtimeNames: Record<string, string> = {
  claude: "Claude", grok: "Grok", copilot: "Copilot", cursor: "Cursor", codex: "Codex", gemini: "Gemini",
  antigravity: "Antigravity", opencode: "OpenCode",
};

/** PoolWords.runtimeName: the catalog's name, else the id as written. */
export function runtimeName(id: string): string {
  return runtimeNames[id] ?? id;
}

/** PoolWords.time: "07:00" today, "Tue 07:00" within the week, a date after that. */
export function switchTime(date: Date, now: Date): string {
  const clock = date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  if (date.toDateString() === now.toDateString()) return clock;
  if (date.getTime() - now.getTime() < 6 * 86_400_000) return `${date.toLocaleDateString([], { weekday: "short" })} ${clock}`;
  return date.toLocaleDateString([], { day: "numeric", month: "short" });
}

/** PoolWords.payment, with nothing known of what was spent. */
function payment(billing: Payment): string {
  if ("allowance" in billing) return billing.allowance.label ? `Allowance · ${billing.allowance.label}` : "Allowance";
  if ("freeTier" in billing) return "dailyAt" in billing.freeTier.reset ? "Free tier · resets daily" : "Free tier";
  return "freeCredit" in billing ? "Free credit" : "Prepaid credit";
}

export function switchNote(record: SwitchRecord, now = new Date()): { headline: string; lines: string[] } {
  const from = runtimeName(record.from.runtimeID);
  const to = runtimeName(record.to.runtimeID);
  const headline = (() => {
    switch (record.reason) {
      case "allowanceSpent":
        return record.fromReturnsAt !== undefined
          ? `${from}’s allowance ran out. Its provider says it resets at ${switchTime(fromWireDate(record.fromReturnsAt), now)}. Carried on with ${to}.`
          : `${from}’s allowance ran out. Carried on with ${to}.`;
      case "overage": return `${from} started using paid extra usage. Carried on with ${to}.`;
      case "creditUsedUp": return `${from}’s credit was used up. Carried on with ${to}.`;
      case "rateLimitPersisted": return `${from} stayed rate limited. Carried on with ${to}.`;
      case "runtimeFailed": return `${from} failed. Carried on with ${to}.`;
      case "everyoneOutResumed": return `${to}’s allowance came back. Carried on.`;
      case "byHand": return `Continued with ${to}.`;
    }
  })();
  const lines: string[] = [];
  const settings = record.carried.flatMap((setting) => {
    if (typeof setting.to !== "string") return [];
    const source = setting.source;
    const whence = "level" in source ? `from your “${source.level._0}” level`
      : "sameValue" in source ? "the same as before"
      : "poolEntry" in source ? "from the pool entry"
      : "remembered" in source ? `the last one chosen for ${to}`
      : "runtimeDefault" in source ? `${to}’s default`
      : "strictestMode" in source ? `${to}’s strictest`
      : "closestNoLooser" in source ? "the closest that is no looser"
      : "chosen by you";
    return [`${setting.name}: ${setting.to}, ${whence}`];
  });
  if (settings.length > 0) lines.push(settings.join(" · "));
  lines.push(record.reason === "byHand" ? `${to} is given the conversation so far with your next message.`
    : "Given the whole conversation so far, and your last message again.");
  if (record.shortened !== undefined && record.shortened > 0) {
    lines.push(`The conversation was too long to hand over whole: ${record.shortened} earlier turns were left out.`);
  }
  const dropped = record.dropped.map((item) => "extraArguments" in item ? `extra arguments ${item.extraArguments._0.join(" ")}`
    : "alwaysAllow" in item ? `${item.alwaysAllow.count} “always allow” answer${item.alwaysAllow.count === 1 ? "" : "s"}, so ${to} may ask again`
    : `a queued ${item.queuedSlashCommand._0}, which ${to} does not have; it is held until you edit it`);
  if (dropped.length > 0) lines.push(`Not carried: ${dropped.join("; ")}.`);
  if (!("allowance" in record.billing)) lines.push(`Now on ${payment(record.billing)}.`);
  return { headline, lines };
}
