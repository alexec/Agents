// The achievements (#984): the first steps a person has taken in Agents, kept on the host. The
// page's half of `Achievements` in Swift: the same list in the same order, and the one-time card
// only for what was earned while this browser has been looking. Which ones it has shown are
// kept in localStorage, as the window keeps them in defaults; bounded by the list itself.
import { signal } from "@preact/signals";
import type { Achievements } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export type AchievementID =
  | "firstAgent" | "firstPairing" | "firstRemoteAnswer" | "firstWorkflow" | "firstCloudHost" | "firstLandedPR" | "fiveAtOnce";

/** Every achievement, in the order a newcomer meets them, with `Achievement.title` and `.how`. */
export const achievementList: { id: AchievementID; title: string; how: string }[] = [
  { id: "firstAgent", title: "First agent started", how: "Start an agent and let it run a turn." },
  { id: "firstPairing", title: "First phone or browser paired", how: "Pair a phone or a browser with Pair a Device…." },
  { id: "firstRemoteAnswer", title: "First question answered away from the Mac",
    how: "Answer an agent's question from the Remote or the web page." },
  { id: "firstWorkflow", title: "First workflow made", how: "Make a workflow that runs an agent on a schedule or an event." },
  { id: "firstCloudHost", title: "First cloud machine started", how: "Start a machine on a cloud provider." },
  { id: "firstLandedPR", title: "First pull request landed with nobody watching",
    how: "Let an agent open a pull request that merges by itself." },
  { id: "fiveAtOnce", title: "Five agents working at once", how: "Have five agents in a turn at the same time." },
];

export interface AchievementRow { id: AchievementID; title: string; how: string; at: Date | null }

/** Earned first, earliest first, then the rest in order, as `Achievements.ordered`. */
export function orderedAchievements(achievements: Achievements): AchievementRow[] {
  const at = (id: string) => achievements.earned.find((e) => e.id === id)?.at;
  const rows = achievementList.map((m) => {
    const earned = at(m.id);
    return { ...m, at: earned === undefined ? null : fromWireDate(earned) };
  });
  const done = rows.filter((r) => r.at).sort((a, b) => a.at!.getTime() - b.at!.getTime());
  return [...done, ...rows.filter((r) => !r.at)];
}

export function isComplete(achievements: Achievements): boolean {
  return achievementList.every((m) => achievements.earned.some((e) => e.id === m.id));
}

/** As `Achievements.unseen`: the first look takes everything earned so far as seen. */
export function unseenAchievements(achievements: Achievements, seen: Set<string> | null): { show: AchievementID[]; seen: Set<string> } {
  const ids = new Set(achievements.earned.map((e) => e.id));
  if (!seen) return { show: [], seen: ids };
  return { show: orderedAchievements(achievements).filter((r) => r.at && !seen.has(r.id)).map((r) => r.id), seen };
}

/** "12 Oct 2026". */
export function achievementDay(date: Date): string {
  return date.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
}

const storageKey = "agents.achievements.seen";

/** The achievements this browser has shown a card for; null before its first look. */
export class AchievementsSeen {
  readonly seen = signal<Set<string> | null>(null);

  constructor(private readonly storage: Storage | undefined) {
    try {
      const stored = JSON.parse(storage?.getItem(storageKey) ?? "null");
      if (Array.isArray(stored)) this.seen.value = new Set(stored.filter((id) => typeof id === "string"));
    } catch {
      // Unreadable: a first look again, which shows no card.
    }
  }

  /** What the host said: on the first look, everything earned so far is taken as seen. */
  take(achievements: Achievements): void {
    if (this.seen.peek() === null) this.keep(unseenAchievements(achievements, null).seen);
  }

  /** The card to show, if any. */
  card(achievements: Achievements | undefined): AchievementID | undefined {
    return achievements ? unseenAchievements(achievements, this.seen.value).show[0] : undefined;
  }

  dismiss(id: AchievementID): void {
    this.keep(new Set([...(this.seen.peek() ?? []), id]));
  }

  private keep(seen: Set<string>): void {
    this.seen.value = seen;
    try {
      this.storage?.setItem(storageKey, JSON.stringify([...seen].sort()));
    } catch {
      // A private window may refuse to store; the card still goes for this visit.
    }
  }
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
export const achievementsSeen = new AchievementsSeen(globalThis.window?.localStorage);
