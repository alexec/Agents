// Part of the Store (#5384): events.
import type { Agent, UUID, BusEvent, Event as ActivityEvent } from "../../protocol/generated";
import { busLogQuery, type EnvelopeFilter } from "../eventBus";
import type { Store } from "../store";
import { eventsKept, eventsPagedMost } from "./shared";

export const eventsMethods = {
  /** Finds a consequence's session by id when it is not already among the loaded rows. */
  async loadEventAgent(this: Store, host: string, agentID: string): Promise<Agent | undefined> {
    const existing = this.agent(host, agentID);
    if (existing) return existing;
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: true, archivedOnly: false, lean: false,
      agentID: agentID as UUID, limit: 1,
    }, host).catch(() => null);
    const agent = listed?.find((candidate: Agent) => candidate.id === agentID);
    if (agent) this.addAgents([agent], host);
    return agent;
  },
  /**
   * The newest page, laid over what is held. The list keeps `eventsKept` of them, as the window's
   * live events (#3650); what goes is still the host's, and paging back brings it in.
   */
  async loadEvents(this: Store, host: string, limit = 50): Promise<void> {
    const page = await this.link.call("events/list", { limit }, host).catch(() => null);
    if (page) {
      const older = this.events.value[host]?.events ?? [];
      const merged = [...page.events, ...older.filter((event) => !page.events.some((next: ActivityEvent) => next.position === event.position))]
        .sort((a: ActivityEvent, b: ActivityEvent) => b.position - a.position);
      const hasMore = page.hasMore || merged.length > eventsKept;
      this.events.value = { ...this.events.value, [host]: { ...page, events: merged.slice(0, eventsKept), hasMore } };
    }
  },
  /** The newest page of the bus log, narrowed by the envelope's fields; an older page with `older`. */
  async loadBusLog(this: Store, filter: EnvelopeFilter, older = false): Promise<void> {
    const held = this.busLog.value;
    if (older && !held?.next) return;
    const page = await this.link.call("bus/log", busLogQuery(filter, older ? held?.next : undefined)).catch(() => null);
    if (!page) return;
    const now = this.busLog.value;
    // A page for a filter since left is too late.
    if (older && (!now || JSON.stringify(now.filter) !== JSON.stringify(filter))) return;
    const events = older && now ? [...now.events, ...page.events.filter((e: BusEvent) => !now.events.some((n) => n.id === e.id))] : page.events;
    const kept = events.slice(0, eventsPagedMost);
    // `at`: when the newest page was read (#5146), for the page's "Last update" line; an older page leaves it.
    const at = older && now ? now.at : Date.now();
    this.busLog.value = { events: kept, filter, at, ...(page.hasMore && page.next !== undefined && kept.length < eventsPagedMost && { next: page.next }) };
  },
  /** Events ▸ Waiting now's ✕ (#541): the wait ends and nothing starts the agent again for it. */
  async cancelWait(this: Store, host: string, agentID: string): Promise<void> {
    const waiting = await this.act("events/cancelWait", { agentID: agentID as UUID }, host);
    const held = this.events.value[host];
    if (waiting && held) this.events.value = { ...this.events.value, [host]: { ...held, waiting } };
    await this.loadEvents(host);
  },
  /** Appends one older page without losing the current head or waiting rows. */
  async loadOlderEvents(this: Store, host: string): Promise<void> {
    const current = this.events.value[host];
    const before = current?.events[current.events.length - 1]?.position;
    if (!current?.hasMore || before === undefined) return;
    const page = await this.link.call("events/list", { limit: 100, before }, host).catch(() => null);
    if (!page) return;
    const held = this.events.value[host];
    if (!held) return;
    const byPosition = new Map([...held.events, ...page.events].map((event: ActivityEvent) => [event.position, event]));
    const events = [...byPosition.values()].sort((a, b) => b.position - a.position);
    // Paging back stops at eventsPagedMost (#3650), as in the window.
    this.events.value = { ...this.events.value, [host]: {
      ...held, events: events.slice(0, eventsPagedMost), hasMore: page.hasMore && events.length < eventsPagedMost,
    } };
  },
  async loadCost(this: Store, host: string): Promise<void> {
    const state = await this.link.call("cost/state", {}, host).catch(() => null);
    if (state) { this.costs.value = { ...this.costs.value, [host]: state }; this.usageRead(host, "cost"); }
  },
  /** A host too old to know the method leaves the charts out. */
  async loadUsage(this: Store, host: string): Promise<void> {
    const history = await this.link.call("usage/history", {}, host).catch(() => null);
    if (history) { this.usage.value = { ...this.usage.value, [host]: history }; this.usageRead(host, "usage"); }
  },
  /** A host too old to know the method leaves the Time page loading. */
  async loadTime(this: Store, host: string): Promise<void> {
    const history = await this.link.call("time/history", {}, host).catch(() => null);
    if (history) { this.time.value = { ...this.time.value, [host]: history }; this.usageRead(host, "time"); }
  },
  /** A host too old to know the method leaves the Velocity page loading. */
  async loadVelocity(this: Store, host: string): Promise<void> {
    const history = await this.link.call("velocity/history", {}, host).catch(() => null);
    if (history) { this.velocity.value = { ...this.velocity.value, [host]: history }; this.usageRead(host, "velocity"); }
  },
};
