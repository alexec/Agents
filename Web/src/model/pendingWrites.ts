import type { Agent, AgentState, UUID } from "../protocol/generated";
import { toWireDate } from "../protocol/dates";
import { labelKey } from "./labels";

/**
 * A change to one agent's record that a person asked for, drawn before its host answers
 * (#4786; AgentWrite.swift). The page's copy changes at once; the change stays pending until the
 * host's record agrees, and goes back when the call fails. Only what the host will do too.
 */
export type AgentWrite =
  | { kind: "archive" }
  | { kind: "unarchive" }
  | { kind: "stop" }
  | { kind: "rename"; title: string }
  | { kind: "labels"; add: string[]; remove: string[] }
  | { kind: "mute"; muted: boolean }
  | { kind: "sendNow"; promptID: string };

/** The verb for the line that says what failed: "Could not archive". */
export function writeVerb(write: AgentWrite): string {
  switch (write.kind) {
    case "labels": return "change the labels";
    case "mute": return write.muted ? "mute" : "unmute";
    case "sendNow": return "send now";
    default: return write.kind;
  }
}

/** The one line the page shows when the call failed: what failed, then why. */
export function writeFailure(write: AgentWrite, reason: string): string {
  return failureLine(writeVerb(write), reason);
}

/** "Could not <verb> — <why>", for any change drawn before its host answered (#4786, #4814). */
export function failureLine(verb: string, reason: string): string {
  const why = reason.trim();
  const head = `Could not ${verb}`;
  return why ? `${head} — ${why.charAt(0).toLowerCase()}${why.slice(1)}` : `${head}.`;
}

/** `value` without the named fields: an optional field is left out, never set to undefined. */
export function omitting<T extends object, K extends keyof T>(value: T, ...keys: K[]): T {
  const copy = { ...value };
  for (const key of keys) delete copy[key];
  return copy;
}

/** The states Stop ends: a turn in flight, or a start still in line. */
function stops(state: AgentState): boolean {
  return state === "starting" || state === "running" || state === "waitingOnUser" || state === "queued";
}

/** The record as the person expects to see it once the host has done this. */
export function applyWrite(agent: Agent, write: AgentWrite, now = new Date()): Agent {
  switch (write.kind) {
    case "archive":
      return { ...omitting(agent, "archiveRequest"), state: "archived", archivedAt: agent.archivedAt ?? toWireDate(now),
        archivedReason: "byUser" };
    case "unarchive":
      if (agent.state !== "archived") return agent;
      // As the host does: finished for a turn that ended itself, stopped otherwise.
      return { ...omitting(agent, "archivedAt", "archivedReason"), state: agent.endedReason === "endTurn" ? "finished" : "stopped",
        endedReason: agent.endedReason ?? "unrecognised" };
    case "stop":
      return stops(agent.state) ? { ...agent, state: "stopped", endedReason: "cancelled" } : agent;
    case "rename": {
      const title = write.title.trim();
      if (!title) {
        const back = agent.titleIsPersons ? agent.runtimeTitle : agent.title;
        const cleared = { ...omitting(agent, "runtimeTitle", "title"), titleIsPersons: false };
        return back === undefined ? cleared : { ...cleared, title: back };
      }
      const theirs = agent.titleIsPersons ? agent.runtimeTitle : agent.title;
      const renamed = { ...omitting(agent, "runtimeTitle"), title, titleIsPersons: true };
      return theirs === undefined ? renamed : { ...renamed, runtimeTitle: theirs };
    }
    case "labels": {
      const gone = new Set(write.remove.map(labelKey));
      const labels = (agent.labels ?? []).filter((l) => !gone.has(labelKey(l.value)));
      for (const value of write.add) {
        if (!labels.some((l) => labelKey(l.value) === labelKey(value))) {
          labels.push({ value, owner: "person", addedAt: toWireDate(now) });
        }
      }
      return { ...agent, labels };
    }
    case "mute":
      return { ...agent, isMuted: write.muted };
    case "sendNow":
      return { ...agent, queuedPrompts: (agent.queuedPrompts ?? []).filter((p) => p.id !== (write.promptID as UUID)) };
  }
}

/** Whether the host's record already says this happened, so the pending change can go. */
export function isSettled(agent: Agent, write: AgentWrite): boolean {
  switch (write.kind) {
    case "archive": return agent.state === "archived";
    case "unarchive": return agent.state !== "archived";
    case "stop": return !stops(agent.state);
    case "rename": {
      const title = write.title.trim();
      return title ? !!agent.titleIsPersons && agent.title === title : !agent.titleIsPersons;
    }
    case "labels": {
      const held = new Set((agent.labels ?? []).map((l) => labelKey(l.value)));
      return write.add.every((v) => held.has(labelKey(v))) && write.remove.every((v) => !held.has(labelKey(v)));
    }
    case "mute": return !!agent.isMuted === write.muted;
    case "sendNow": return !(agent.queuedPrompts ?? []).some((p) => p.id === (write.promptID as UUID));
  }
}

interface Pending { id: number; write: AgentWrite; answered: boolean }

/**
 * Every pending change, by `host|agentID`, and the host's own record under each: the one layer
 * the store draws every agent through (#4786), so no action keeps its own copy.
 */
export class PendingWrites {
  private writes = new Map<string, Pending[]>();
  private records = new Map<string, Agent>();
  private shown = new Map<string, Agent>();
  private sequence = 0;

  has(host: string, agentID: string): boolean { return this.writes.has(`${host}|${agentID}`); }

  /** A change begun on `shown`: the record to show now, and which change it was. */
  begin(host: string, shown: Agent, write: AgentWrite): { id: number; agent: Agent } {
    const key = `${host}|${shown.id}`;
    const id = ++this.sequence;
    if (!this.records.has(key)) this.records.set(key, shown);
    this.writes.set(key, [...(this.writes.get(key) ?? []), { id, write, answered: false }]);
    return { id, agent: this.remember(key, applyWrite(shown, write)) };
  }

  /**
   * The call came back. Failed, the change goes and the host's record comes back with any other
   * change drawn over it; answered, it stays until the host's record says so or the host next
   * speaks of the agent. The record to show, or null when nothing changes on screen yet.
   */
  settle(host: string, agentID: string, id: number, failed: boolean): Agent | null {
    const key = `${host}|${agentID}`;
    const writes = this.writes.get(key);
    const record = this.records.get(key);
    const at = writes?.findIndex((w) => w.id === id) ?? -1;
    if (!writes || !record || at < 0) return null;
    if (!failed && !isSettled(record, writes[at]!.write)) {
      writes[at] = { ...writes[at]!, answered: true };
      return null;
    }
    writes.splice(at, 1);
    if (!writes.length) {
      this.forget(key);
      return record;
    }
    return this.remember(key, writes.reduce((a, w) => applyWrite(a, w.write), record));
  }

  /**
   * One agent of a list on its way to the screen: the copy already shown passes as it is, a
   * record from the host has what is still pending drawn over it.
   */
  overlay(host: string, agent: Agent): Agent {
    const key = `${host}|${agent.id}`;
    const writes = this.writes.get(key);
    if (!writes || this.shown.get(key) === agent) return agent;
    const left = writes.filter((w) => !w.answered && !isSettled(agent, w.write));
    if (!left.length) {
      this.forget(key);
      return agent;
    }
    this.writes.set(key, left);
    this.records.set(key, agent);
    return this.remember(key, left.reduce((a, w) => applyWrite(a, w.write), agent));
  }

  private remember(key: string, agent: Agent): Agent {
    this.shown.set(key, agent);
    return agent;
  }

  private forget(key: string): void {
    this.writes.delete(key);
    this.records.delete(key);
    this.shown.delete(key);
  }
}
