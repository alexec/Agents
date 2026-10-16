// What each runtime offered the new session's form last time, on each host (#1171). The form
// opens on it at once, ready to send, rather than on "Asking…" until its draft answers; the
// answer still comes and puts the menus right, keeping each choice it still offers. A start sent
// before the answer carries the chosen options, and the host applies them to the session it
// makes. One list for each runtime on each host, the last one heard.
import type { ConfigOption, JSONValue } from "../protocol/generated";
import { choices, same } from "./options";

const offered = new Map<string, ConfigOption[]>();

const key = (host: string, runtimeID: string) => `${host}\n${runtimeID}`;

export function rememberedOptions(host: string, runtimeID: string): ConfigOption[] | undefined {
  return offered.get(key(host, runtimeID));
}

export function rememberOptions(host: string, runtimeID: string, options: ConfigOption[]): void {
  offered.set(key(host, runtimeID), options);
}

export function rememberedCount(): number {
  return offered.size;
}

/** Choices still offered are kept; the rest open on the runtime's current value. */
export function keep(options: ConfigOption[], chosen: Record<string, JSONValue>): Record<string, JSONValue> {
  const kept: Record<string, JSONValue> = {};
  for (const option of options) {
    const was = chosen[option.id];
    if (was !== undefined && (option.type === "boolean" || choices(option).some((c) => same(c.value, was)))) kept[option.id] = was;
    else if (option.currentValue !== undefined) kept[option.id] = option.currentValue;
  }
  return kept;
}
