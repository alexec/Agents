// Status ▸ Events' grey line: how many sessions wait for an event, as the window's and the
// Remote's EventsRow (EventsWords.waitingLine). It has no time: a wait's age says nothing.
import type { EventsChange, EventsPage } from "../protocol/generated";

/** "4 sessions waiting" over every machine's held page; undefined when none waits. */
export function eventsWaitingLine(pages: Record<string, EventsPage>): string | undefined {
  const count = Object.values(pages).reduce((sum, page) => sum + page.waiting.length, 0);
  if (count === 0) return undefined;
  return count === 1 ? "1 session waiting" : `${count} sessions waiting`;
}

/** A host's events/changed laid over its held page: the waiting list it says, and its event at the head. */
export function takeEventsChange(held: EventsPage | undefined, change: EventsChange): EventsPage {
  const events = held?.events ?? [];
  const event = change.event;
  const known = event !== undefined && events.some((e) => e.position === event.position);
  return {
    ...(held ?? { hasMore: false }),
    waiting: change.waiting,
    events: event && !known ? [event, ...events] : events,
  };
}
