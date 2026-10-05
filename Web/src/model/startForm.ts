// The new session's form as it was left (#257): its runtime, the choices made on it and the
// folders it may also reach, kept across starts and a reload, as the window's DraftKeeper keeps
// its start form. One form, as the window has one; a runtime that is gone takes its choices
// with it, since they were that runtime's.
import type { JSONValue } from "../protocol/generated";

export interface StartForm {
  runtimeID?: string;
  chosen: Record<string, JSONValue>;
  folders: string[];
}

interface Storage { getItem(key: string): string | null; setItem(key: string, value: string): void }

const storageKey = "agents.startForm";

export function keptForm(storage: Storage | undefined): StartForm {
  try {
    const kept = JSON.parse(storage?.getItem(storageKey) ?? "null") as Partial<StartForm> | null;
    return {
      ...(typeof kept?.runtimeID === "string" ? { runtimeID: kept.runtimeID } : {}),
      chosen: kept?.chosen && typeof kept.chosen === "object" ? kept.chosen : {},
      folders: Array.isArray(kept?.folders) ? kept.folders.filter((f): f is string => typeof f === "string") : [],
    };
  } catch {
    return { chosen: {}, folders: [] };
  }
}

export function keepForm(storage: Storage | undefined, form: StartForm): void {
  try { storage?.setItem(storageKey, JSON.stringify(form)); } catch { /* full: not kept */ }
}

/** The form's runtime when it can still start, the choices made on it only then. */
export function formFor(form: StartForm, startable: readonly string[]): StartForm {
  if (form.runtimeID && startable.includes(form.runtimeID)) return form;
  const { runtimeID: _gone, ...rest } = form;
  return { ...rest, chosen: {} };
}
