// What an agent told the person with `notify` (#2805): the words after the line's time,
// as SentNotice.outcomeText says them on the Mac and the Remote.
import type { NoticeDevice, SentNotice } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

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

