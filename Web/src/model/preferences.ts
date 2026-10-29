// The person's display choices (#1033), kept once on their Mac's host in
// ~/.agents/settings/display.json, so the window, the Remote and this page show the same. The
// page keeps no copy: the store fills `preferences` from the Mac's `preferences/get` and each
// `preferences/changed`, and a choice made here is sent with `preferences/set`. The keys are
// DisplayPreference's.
import { signal } from "@preact/signals";
import type { JSONValue } from "../protocol/generated";

export const preferenceKeys = {
  smartGroupsOff: "sidebarSmartGroupsOff",
  showsArchivedFolders: "showsArchivedFolders",
  showsActivity: "showsActivity",
  showsUsage: "showsUsage",
  startRuntimeID: "startRuntimeID",
  startChoices: "startChoices",
  agentsMayArchiveMyChats: "agentsMayArchiveMyChats",
  noticeBurst: "noticeBurst",
  noticeCooldownMinutes: "noticeCooldownMinutes",
} as const;

/** The Mac's map, as last heard; empty until it is, which is every choice at its default. */
export const preferences = signal<Record<string, JSONValue>>({});

let sender: ((changes: Record<string, JSONValue | null>) => void) | null = null;

/** The store says where a change goes: the Mac's host, once connected. */
export function sendPreferencesWith(send: ((changes: Record<string, JSONValue | null>) => void) | null): void {
  sender = send;
}

/** What the Mac said. */
export function preferencesSaid(said: Record<string, JSONValue>): void {
  preferences.value = said;
}

/** Set some of them: drawn at once, and sent. A null removes the key, so its default shows. */
export function setPreferences(changes: Record<string, JSONValue | null>): void {
  const next = { ...preferences.peek() };
  for (const [key, value] of Object.entries(changes)) {
    if (value === null) delete next[key];
    else next[key] = value;
  }
  preferences.value = next;
  sender?.(changes);
}

export function stringPreference(key: string): string | undefined {
  const value = preferences.value[key];
  return typeof value === "string" ? value : undefined;
}

export function numberPreference(key: string): number | undefined {
  const value = preferences.value[key];
  return typeof value === "number" ? value : undefined;
}

export function boolPreference(key: string): boolean | undefined {
  const value = preferences.value[key];
  return typeof value === "boolean" ? value : undefined;
}
