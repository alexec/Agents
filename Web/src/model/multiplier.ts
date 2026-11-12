// The Multiplier page (#3990): the page's half of the window's MultiplierPage, Crowd and EarnedBadges
// (#3904, #3985–#3988). The host counts the figures (#3903); here are the crowd's count and layout,
// the rising line's words, and the earned badges with the Next line.
import type { Achievements, Multiplier } from "../protocol/generated";
import { achievementList, orderedAchievements, type AchievementID } from "./achievements";
import { legacyRef } from "../protocol/ref";

/** The most Blobs drawn; past it, one Blob is `bigEach` engineers. */
export const crowdCap = 1000;
export const bigEach = 10;
/** A Blob in its own units, as `Blob.size` in Swift. */
export const blobSize = { width: 600, height: 580 };

/** How many Blobs a Multiplier is: the whole part, and one more, faint, for the fraction (`CrowdCount`). */
export interface CrowdCount { each: number; blobs: number; fraction: number }

export function crowdCount(multiplier: number): CrowdCount {
  const value = Math.max(multiplier, 0);
  const each = value > crowdCap ? bigEach : 1;
  const scaled = value / each;
  const whole = Math.floor(scaled);
  const part = scaled - whole;
  const fraction = part > 0.05 ? part : 0;
  return { each, blobs: whole + (fraction > 0 ? 1 : 0), fraction };
}

export interface CrowdPlace { x: number; y: number; scale: number; seed: number }
export interface CrowdLayout { places: CrowdPlace[]; drawingOrder: number[]; youScale: number }

export const emptyLayout: CrowdLayout = { places: [], drawingOrder: [], youScale: 0.135 };

/** Where each engineer stands (`CrowdLayout`): a mound of rows around you, the nearest places first. */
export function crowdLayout(blobs: number, width: number, height: number): CrowdLayout {
  if (blobs <= 0 || width <= 0) return emptyLayout;
  const a = width / 2, b = height;
  const cell = Math.min(Math.sqrt((Math.PI * a * b / 2) / (blobs * 0.52)) * 0.9, 70);
  const rowStep = cell * 0.52, middle = width / 2, base = height - cell * 0.45;
  const rows = Math.ceil(b / rowStep) + 2, columns = Math.ceil(width / cell) + 2;
  const cells: { x: number; y: number; distance: number }[] = [];
  for (let row = 0; row < rows; row++) {
    for (let column = -columns; column <= columns; column++) {
      const x = middle + (column + (row % 2) * 0.5) * cell;
      const y = base - row * rowStep;
      if (x < cell / 2 || x > width - cell / 2 || y < cell / 2) continue;
      // Your place, in front.
      if (row === 0 && Math.abs(x - middle) < Math.max(cell * 0.9, 40)) continue;
      const dx = (x - middle) / a, dy = (base - y + cell * 0.6) / b;
      cells.push({ x, y, distance: dx * dx + dy * dy });
    }
  }
  cells.sort((p, q) => p.distance - q.distance);
  const scale = cell / blobSize.width * 0.86;
  const places = cells.slice(0, blobs).map((c, index) => {
    const seed = ((index * 9301 + 49297) % 233_280) / 233_280;
    const shake = (seed * 7) % 1;
    return { x: c.x + (seed - 0.5) * cell * 0.18, y: c.y + (shake - 0.5) * cell * 0.12, scale, seed };
  });
  const drawingOrder = places.map((_, i) => i).sort((i, j) => places[i]!.y - places[j]!.y);
  return { places, drawingOrder, youScale: Math.min(Math.max(0.065, cell * 1.15 / blobSize.width), 0.135) };
}

/** How likely a Blob is to blink at each tick, as `Crowd.blinkChance`; yours too. */
export const BLINK_CHANCE = 0.25;
/** The most Blobs that blink at one tick, as `Crowd.mostBlinking`. */
export const MOST_BLINKING = 5;

/**
 * The Blobs that blink at one tick, as `Crowd.blinkers`: each with `BLINK_CHANCE`, at most
 * `MOST_BLINKING`, so a crowd of one or two does not blink every tick (#4194).
 */
export function blinkers(blobs: number, random: () => number = Math.random): Set<number> {
  if (blobs <= 0) return new Set();
  if (blobs > MOST_BLINKING * 4) {
    const n = 1 + Math.floor(random() * MOST_BLINKING);
    return new Set(Array.from({ length: n }, () => Math.floor(random() * blobs)));
  }
  const chosen: number[] = [];
  for (let i = 0; i < blobs; i++) if (random() < BLINK_CHANCE) chosen.push(i);
  return new Set(chosen.slice(0, MOST_BLINKING));
}

/** A light blue a little different for each engineer, as `Crowd.fill`. */
export function crowdFill(seed: number, dark: boolean): string {
  return dark ? hsb(212 + seed * 10, 0.46 - seed * 0.13, 0.91 + seed * 0.03) : hsb(210 + seed * 12, 0.28 - seed * 0.12, 1);
}

/** Hue in degrees, saturation and brightness 0 to 1, as SwiftUI's Color(hue:saturation:brightness:). */
function hsb(hue: number, saturation: number, brightness: number): string {
  const channel = (n: number) => {
    const k = (n + hue / 60) % 6;
    return Math.round(255 * (brightness - brightness * saturation * Math.max(0, Math.min(k, 4 - k, 1))));
  };
  return `rgb(${channel(5)} ${channel(3)} ${channel(1)})`;
}

/** One decimal, as the window writes it: 3.2. */
export const oneDecimal = (value: number) => value.toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
/** A whole number: 128. */
export const whole = (value: number) => Math.round(value).toLocaleString();

/** The PR's number as people write it, `#1234`, from a ref such as `github:alexec/agents#1234` (`shortName`). */
export function prShortName(full: string): string {
  const ref = legacyRef(full);
  const hash = ref.lastIndexOf("#");
  return hash < 0 ? ref : ref.slice(hash);
}

/** The line under the figures: the person's own, else "An average engineer merged 1.4 PRs a week (DX 2025)". */
export function baselineLine(m: Multiplier): string {
  return m.baseline.line ?? `An average engineer merged ${m.baseline.prsPerWeek.toLocaleString()} PRs a week (${m.baseline.source})`;
}

/** The words under `— ×` when nothing is counted (#4250), as the window's `emptyWords`: for a person whose
 * agents have not merged a PR yet, a start, not a failure; else, that the last 7 days had none. `small` is
 * absent when it would say the person's own line, which the page shows anyway. */
export function emptyWords(m: Multiplier): { big: string; small?: string } {
  if (m.firstMergeAt !== undefined) return { big: "No merged work in the last 7 days." };
  const big = "Your first merged PR starts the count.";
  if (m.baseline.line !== undefined) return { big };
  return { big, small: `Each PR your agents merge counts against an engineer’s ${oneDecimal(m.baseline.prsPerWeek)} PRs a week.` };
}

/** The rising line for the PR that changed the figure: `+0.3×  #1234 merged`, or `New best week: 4.3×`;
 * none when nothing merged (a baseline change). */
export function newsOf(old: Multiplier | undefined, now: Multiplier): { words: string; up: boolean } | undefined {
  const pr = now.changedBy;
  if (!pr) return undefined;
  const reverted = now.prsMerged < (old?.prsMerged ?? 0);
  if (now.bestWeek !== undefined && old?.bestWeek !== undefined && now.bestWeek > old.bestWeek) {
    return { words: `New best week: ${oneDecimal(now.bestWeek)}×`, up: !reverted };
  }
  const change = (now.multiplier ?? 0) - (old?.multiplier ?? 0);
  return { words: `${change < 0 ? "−" : "+"}${oneDecimal(Math.abs(change))}×  ${prShortName(pr.ref)} ${reverted ? "reverted" : "merged"}`, up: !reverted };
}

/** A glyph for each achievement's badge, in place of the window's SF Symbols. */
export const badgeGlyph: Record<AchievementID, string> = {
  firstAgent: "▶︎", firstPairing: "⇄", firstRemoteAnswer: "❞", firstWorkflow: "◷", firstCloudHost: "☁︎",
  firstLandedPR: "⑂", fiveAtOnce: "⑤",
};

export interface Badge { id: AchievementID; title: string; at: Date }

/** The earned ones, earliest first, and the first still to earn, in the order a newcomer meets them. */
export function earnedBadges(achievements: Achievements | undefined): { badges: Badge[]; next: typeof achievementList[number] | undefined } {
  const rows = achievements ? orderedAchievements(achievements) : [];
  const badges = rows.filter((r) => r.at).map((r) => ({ id: r.id, title: r.title, at: r.at! }));
  return { badges, next: achievementList.find((m) => !badges.some((b) => b.id === m.id)) };
}
