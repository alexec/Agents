// The Events page reads the bus (#4732, spec 4724-event-bus, "Where agents and people use it"):
// every host's own log, with its sentences and consequences, and the person's bus log for what
// no listed host has, by the event's ref. The same rules as the window's `AgentsModel.shownEvents`.
import type { BusEvent, BusLogQuery, Event } from "../protocol/generated";
import { toWireDate } from "../protocol/dates";

/** The envelope's provider, type and topic (#4732); undefined: every one. */
export interface EnvelopeFilter {
  provider?: string;
  type?: string;
  topic?: string;
}

/** One row of the page: a host's event, or the bus's (no host) that no host here has. */
export interface EventItem {
  host?: string;
  event: Event;
}

/** Whether an event's envelope passes the filter; an event from before it matches by its name. */
export function envelopeMatches(filter: EnvelopeFilter, event: Event): boolean {
  return (filter.provider === undefined || event.provider === filter.provider)
    && (filter.type === undefined || (event.type ?? event.name) === filter.type)
    && (filter.topic === undefined || event.topic === filter.topic);
}

/** The same, as `bus/log` takes it. */
export function busLogQuery(filter: EnvelopeFilter, before?: string, limit = 100): BusLogQuery {
  return { limit, ...(before !== undefined && { before }), ...filter };
}

/** A bus envelope as a row: its type and subject for the sentence, a position below zero. */
export function busRow(bus: BusEvent, position: number): Event {
  const at = Date.parse(bus.time);
  return {
    position, name: bus.type, at: toWireDate(Number.isNaN(at) ? new Date() : new Date(at)), count: 1, scope: { mac: {} },
    sentence: bus.subject ? `${bus.type} on ${bus.subject}` : bus.type, details: {}, chainDepth: 0, consequences: [],
    specversion: bus.specversion, id: bus.id, type: bus.type, provider: bus.provider, topic: bus.topic,
    ...(bus.subject && { subject: bus.subject }), source: bus.source, time: bus.time, producer: bus.producer,
  } as Event;
}

/** The machine in a producer ref, `agents:machine:#<machine>`. */
export function producerMachine(producer: string | undefined): string | undefined {
  if (!producer) return undefined;
  const at = producer.indexOf("#");
  return at < 0 ? producer : producer.slice(at + 1) || undefined;
}

/**
 * The hosts' events and the bus's that none of them has, newest first. `bus` is newest first, as
 * `bus/log` gives it.
 */
export function joinBus(hosts: EventItem[], bus: readonly BusEvent[]): EventItem[] {
  const held = new Set(hosts.map(({ event }) => event.id).filter((id): id is string => !!id));
  const others = bus.filter((one) => !held.has(one.id)).map((one, index) => ({ event: busRow(one, -1 - index) }));
  const when = ({ event }: EventItem) => event.lastAt ?? event.at;
  return [...hosts, ...others].sort((a, b) => when(b) - when(a));
}

/** What a menu offers: every value the rows have, and the one picked, sorted. */
export function envelopeChoices(events: readonly Event[], value: (event: Event) => string | undefined, picked?: string): string[] {
  const all = new Set(events.map(value).filter((v): v is string => !!v));
  if (picked) all.add(picked);
  return [...all].sort();
}
