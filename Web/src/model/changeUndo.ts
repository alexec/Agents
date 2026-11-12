// Undo (⌘Z) for an optimistic action that has an inverse (#4793), as SessionUndo.swift says it:
// Unarchive, Rename, the labels, Mute or Unmute, and Later. Archive has its own (archiveWords.undoLine).
// The words are held to Fixtures/web/undo/lines.json.
import type { Agent, Request as PersonRequest } from "../protocol/generated";
import { labelKey } from "./labels";

/** What was done, for the words. */
export type Change =
  | { kind: "unarchived" }
  | { kind: "renamed"; to: string }
  | { kind: "labels"; add: string[]; remove: string[] }
  | { kind: "muted"; muted: boolean }
  | { kind: "later" };

/** What Undo sends. */
export type Inverse =
  | { kind: "archive"; agentID: string }
  | { kind: "rename"; agentID: string; title: string }
  | { kind: "labels"; agentID: string; add: string[]; remove: string[] }
  | { kind: "mute"; agentID: string; muted: boolean }
  | { kind: "bringBack"; request: string };

export interface ChangeUndo { change: Change; title: string | undefined | null; inverse: Inverse }

function shown(title: string | undefined | null): string {
  return title?.trim() || "Untitled";
}

/** SessionUndo.line: "Renamed “Fix the parser” to “Parser”". */
export function changeUndoLine(change: Change, title: string | undefined | null): string {
  const named = `“${shown(title)}”`;
  switch (change.kind) {
    case "unarchived": return `Unarchived ${named}`;
    case "renamed": {
      const to = change.to.trim();
      return to ? `Renamed ${named} to “${to}”` : `Gave ${named} its runtime’s title`;
    }
    case "labels":
      if (change.add.length === 1 && change.remove.length === 0) return `Added the label “${change.add[0]}” to ${named}`;
      if (change.remove.length === 1 && change.add.length === 0) return `Removed the label “${change.remove[0]}” from ${named}`;
      return `Changed the labels of ${named}`;
    case "muted": return change.muted ? `Muted ${named}` : `Unmuted ${named}`;
    case "later": return `Moved ${named} to Later`;
  }
}

/** SessionUndo.menuTitle: the ⌘K menu's item while the toast shows. */
export function changeUndoMenu(change: Change): string {
  switch (change.kind) {
    case "unarchived": return "Undo Unarchive";
    case "renamed": return "Undo Rename";
    case "labels": return "Undo Labels";
    case "muted": return change.muted ? "Undo Mute" : "Undo Unmute";
    case "later": return "Undo Later";
  }
}

/** Unarchive: Undo archives it again. */
export function unarchivedUndo(agent: Agent): ChangeUndo | null {
  if (agent.state !== "archived") return null;
  return { change: { kind: "unarchived" }, title: agent.title, inverse: { kind: "archive", agentID: agent.id } };
}

/** Rename: Undo gives the title it had, the person's or (empty) the runtime's. */
export function renamedUndo(agent: Agent, title: string): ChangeUndo | null {
  const to = title.trim();
  const back = agent.titleIsPersons ? agent.title ?? "" : "";
  if (to === back.trim()) return null;
  return { change: { kind: "renamed", to }, title: agent.title, inverse: { kind: "rename", agentID: agent.id, title: back } };
}

/** A label change: Undo removes only what this added and adds back only what this removed. */
export function labelsUndo(agent: Agent, add: string[], remove: string[]): ChangeUndo | null {
  const held = new Set((agent.labels ?? []).map((l) => labelKey(l.value)));
  const added = add.filter((v) => !held.has(labelKey(v)));
  const gone = new Set(remove.map(labelKey));
  const removed = (agent.labels ?? []).filter((l) => gone.has(labelKey(l.value))).map((l) => l.value);
  if (added.length === 0 && removed.length === 0) return null;
  return { change: { kind: "labels", add: added, remove: removed }, title: agent.title,
    inverse: { kind: "labels", agentID: agent.id, add: removed, remove: added } };
}

/** Mute or Unmute: Undo sets it back. */
export function mutedUndo(agent: Agent, muted: boolean): ChangeUndo | null {
  if (!!agent.isMuted === muted) return null;
  return { change: { kind: "muted", muted }, title: agent.title, inverse: { kind: "mute", agentID: agent.id, muted: !muted } };
}

/** Later on a request: Undo is Bring Back Now. */
export function laterUndo(request: PersonRequest): ChangeUndo {
  return { change: { kind: "later" }, title: request.title, inverse: { kind: "bringBack", request: request.id } };
}
