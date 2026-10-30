// What an agent told the person with `notify` (#2805): the words after the line's time,
// as SentNotice.outcomeText says them on the Mac and the Remote.
import type { NoticeDevice, SentNotice } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { computed } from "@preact/signals";
import { numberPreference, preferenceKeys, setPreferences } from "./preferences";

/** A time as the line shows it: hours and minutes, in the reader's own way. */
export function noticeClock(at: Date): string {
  return at.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

/** Where a sent notice went (#2860), once its host knew. */
const sentTo: Record<NoticeDevice, string> = {
  computer: "Sent to the computer",
  iPhone: "Sent to iPhone",
  iPad: "Sent to iPad",
  device: "Sent to a device",
};

/** What became of the notice. The cool-down's words are the agent's own: the time it was told. */
export function noticeOutcome(notice: SentNotice): string {
  switch (notice.outcome) {
    case "sent":
      return notice.to === undefined ? "Sent" : sentTo[notice.to];
    case "shownHere":
      return "Shown here";
    case "muted":
      return "Muted: not sent";
    case "coolingDown":
      return notice.nextAt === undefined
        ? "Not sent: in the cool-down"
        : `Not sent: the next notice can go at ${noticeClock(fromWireDate(notice.nextAt))}`;
  }
}

// Settings ▸ Notifications (#2805): the person's attention, which every agent on the Mac's host
// shares. Kept in its display preferences, so the window, the Remote and this page show the same.
export const noticeBurstDefault = 3;
export const noticeCooldownDefault = 10;
export const noticeBurstMost = 20;
export const noticeCooldownMost = 1440;

export const noticeBurst = computed(() => numberPreference(preferenceKeys.noticeBurst) ?? noticeBurstDefault);
export const noticeCooldown = computed(() => numberPreference(preferenceKeys.noticeCooldownMinutes) ?? noticeCooldownDefault);

/** A whole number in its bounds, or the default for one that is not a number. */
function bounded(value: number, most: number, fallback: number): number {
  return Number.isFinite(value) ? Math.min(most, Math.max(1, Math.round(value))) : fallback;
}

export function setNoticeBurst(value: number): void {
  setPreferences({ [preferenceKeys.noticeBurst]: bounded(value, noticeBurstMost, noticeBurstDefault) });
}

export function setNoticeCooldown(minutes: number): void {
  setPreferences({ [preferenceKeys.noticeCooldownMinutes]: bounded(minutes, noticeCooldownMost, noticeCooldownDefault) });
}

export const noticeLimitsFooter = "What agents tell you with a notification, when nothing is to be answered. "
  + "Burst is how many can go at once; after that, one comes back each cool-down. "
  + "A notice that would go in the cool-down is not sent, and the agent is told when the next can go. "
  + "Questions and approvals are not limited.";

/** Under the web's limits only (#2895): they sit under This browser, but are the Mac's host's, and the page gets
 * notices while it is open and in front (#2860), or by Web Push when no iPhone gets them (#1486). */
export const noticeLimitsWhere = "Kept on your Mac, the same on every client of yours. "
  + "The notices go to your Mac, iPhone and iPad, and to this browser: while this page is open and in front, "
  + "or by Web Push when no iPhone gets them.";
