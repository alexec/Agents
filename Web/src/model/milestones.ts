// The milestones (#984): the first steps a person has taken in Agents, kept on the host. The
// page's half of `Milestones` in Swift: the same list in the same order, and the one-time card
// only for what was earned while this browser has been looking. Which ones it has shown are
// kept in localStorage, as the window keeps them in defaults; bounded by the list itself.
import { signal } from "@preact/signals";
import type { Milestones } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export type MilestoneID =
  | "firstAgent" | "firstPairing" | "firstRemoteAnswer" | "firstWorkflow" | "firstCloudHost" | "firstLandedPR" | "fiveAtOnce";

/** Every milestone, in the order a newcomer meets them, with `Milestone.title` and `.how`. */
export const milestoneList: { id: MilestoneID; title: string; how: string }[] = [
  { id: "firstAgent", title: "First agent started", how: "Start an agent and let it run a turn." },
  { id: "firstPairing", title: "First phone or browser paired", how: "Pair a phone or a browser with Pair a Device…." },
  { id: "firstRemoteAnswer", title: "First question answered away from the Mac",
    how: "Answer an agent's question from the Remote or the web page." },
  { id: "firstWorkflow", title: "First workflow made", how: "Make a workflow that runs an agent on a schedule or an event." },
  { id: "firstCloudHost", title: "First cloud host started", how: "Start a workspace on a cloud provider." },
  { id: "firstLandedPR", title: "First pull request landed with nobody watching",
    how: "Let an agent open a pull request that merges by itself." },
  { id: "fiveAtOnce", title: "Five agents working at once", how: "Have five agents in a turn at the same time." },
];

export interface MilestoneRow { id: MilestoneID; title: string; how: string; at: Date | null }

/** Earned first, earliest first, then the rest in order, as `Milestones.ordered`. */
export function orderedMilestones(milestones: Milestones): MilestoneRow[] {
  const at = (id: string) => milestones.earned.find((e) => e.id === id)?.at;
  const rows = milestoneList.map((m) => {
    const earned = at(m.id);
    return { ...m, at: earned === undefined ? null : fromWireDate(earned) };
  });
  const done = rows.filter((r) => r.at).sort((a, b) => a.at!.getTime() - b.at!.getTime());
  return [...done, ...rows.filter((r) => !r.at)];
}

export function isComplete(milestones: Milestones): boolean {
  return milestoneList.every((m) => milestones.earned.some((e) => e.id === m.id));
}

/** As `Milestones.unseen`: the first look takes everything earned so far as seen. */
export function unseenMilestones(milestones: Milestones, seen: Set<string> | null): { show: MilestoneID[]; seen: Set<string> } {
  const ids = new Set(milestones.earned.map((e) => e.id));
  if (!seen) return { show: [], seen: ids };
  return { show: orderedMilestones(milestones).filter((r) => r.at && !seen.has(r.id)).map((r) => r.id), seen };
}

/** "12 Oct 2026". */
export function milestoneDay(date: Date): string {
  return date.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
}

const storageKey = "agents.milestones.seen";

/** The milestones this browser has shown a card for; null before its first look. */
export class MilestonesSeen {
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
  take(milestones: Milestones): void {
    if (this.seen.peek() === null) this.keep(unseenMilestones(milestones, null).seen);
  }

  /** The card to show, if any. */
  card(milestones: Milestones | undefined): MilestoneID | undefined {
    return milestones ? unseenMilestones(milestones, this.seen.value).show[0] : undefined;
  }

  dismiss(id: MilestoneID): void {
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
export const milestonesSeen = new MilestonesSeen(globalThis.window?.localStorage);
