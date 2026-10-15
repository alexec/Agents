// The new session's form as it was left (#257): its runtime, the choices made on it and the
// folders it may also reach, kept across starts and a reload, as the window's DraftKeeper keeps
// its start form. The runtime and choices follow the person to every client (#1033). One form, as the window has one; a runtime that is gone takes its choices
// with it, since they were that runtime's.
import type { JSONValue } from "../protocol/generated";
import { preferenceKeys, preferences, setPreferences } from "./preferences";

export interface StartForm {
  runtimeID?: string;
  chosen: Record<string, JSONValue>;
  folders: string[];
}

interface Storage { getItem(key: string): string | null; setItem(key: string, value: string): void }

/** The folders are this browser's (they are paths on one host); the runtime and its choices are
 *  the person's, kept on their Mac with the other display choices (#1033). */
const storageKey = "agents.startForm";

function sharedChoices(): Record<string, JSONValue> {
  const all = preferences.peek()[preferenceKeys.startChoices];
  return all && typeof all === "object" && !Array.isArray(all) ? all : {};
}

export function keptForm(storage: Storage | undefined): StartForm {
  let folders: string[] = [];
  try {
    const kept = JSON.parse(storage?.getItem(storageKey) ?? "null") as Partial<StartForm> | null;
    folders = Array.isArray(kept?.folders) ? kept.folders.filter((f): f is string => typeof f === "string") : [];
  } catch {
    // Unreadable: no folders.
  }
  const runtimeID = preferences.peek()[preferenceKeys.startRuntimeID];
  if (typeof runtimeID !== "string") return { chosen: {}, folders };
  const chosen = sharedChoices()[runtimeID];
  return { runtimeID, chosen: chosen && typeof chosen === "object" && !Array.isArray(chosen) ? chosen : {}, folders };
}

export function keepForm(storage: Storage | undefined, form: StartForm): void {
  try { storage?.setItem(storageKey, JSON.stringify({ folders: form.folders })); } catch { /* full: not kept */ }
  if (!form.runtimeID) return;
  const said = preferences.peek();
  const changes: Record<string, JSONValue> = {};
  if (said[preferenceKeys.startRuntimeID] !== form.runtimeID) changes[preferenceKeys.startRuntimeID] = form.runtimeID;
  const choices = sharedChoices();
  if (Object.keys(form.chosen).length > 0 && JSON.stringify(choices[form.runtimeID]) !== JSON.stringify(form.chosen)) {
    changes[preferenceKeys.startChoices] = { ...choices, [form.runtimeID]: form.chosen };
  }
  if (Object.keys(changes).length > 0) setPreferences(changes);
}

/** The form's runtime when it can still start, the choices made on it only then. */
export function formFor(form: StartForm, startable: readonly string[]): StartForm {
  if (form.runtimeID && startable.includes(form.runtimeID)) return form;
  const { runtimeID: _gone, ...rest } = form;
  return { ...rest, chosen: {} };
}
