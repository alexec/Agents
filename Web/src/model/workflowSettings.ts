// The workflow page's menus (#162): WorkflowSettings.modelOption, effortOption, isNamedOnItsOwn
// and refusalDetail (Model/WorkflowSettings.swift), WorkflowCooldown.fileText, and the window's
// WorkflowPage menus (withDefault, selectable, the cooldown's choices), ported by hand.
//
// The file holds strings, so a menu's value is a string or nothing; nothing leaves the key out,
// which is what each menu's first, "runtime default" choice means.
import type { ConfigChoice, ConfigChoiceGroup, ConfigOption, JSONValue, WorkflowSettings, WorkflowWhenDone } from "../protocol/generated";
import { choiceGroups, choices, isRenderable, modeOption } from "./options";

function selects(options: readonly ConfigOption[]): ConfigOption[] {
  return options.filter((o) => o.type === "select");
}

/** WorkflowSettings.modelOption: by category first, by id second. */
export function modelOption(options: readonly ConfigOption[]): ConfigOption | undefined {
  const s = selects(options);
  return s.find((o) => o.category === "model") ?? s.find((o) => o.id === "model");
}

/** WorkflowSettings.effortOption. */
export function effortOption(options: readonly ConfigOption[]): ConfigOption | undefined {
  const s = selects(options);
  return s.find((o) => o.category === "thought_level")
    ?? s.find((o) => ["effort", "reasoning_effort", "thought_level"].includes(o.id));
}

/** WorkflowSettings.isNamedOnItsOwn: the mode, the model and the effort have keys of their own. */
export function isNamedOnItsOwn(option: ConfigOption, options: readonly ConfigOption[]): boolean {
  return [modeOption(options), modelOption(options), effortOption(options)].some((o) => o?.id === option.id);
}

/** What the runtime advertised besides the mode, the model and the effort: each under `options:`. */
export function otherOptions(options: readonly ConfigOption[]): ConfigOption[] {
  return options.filter((o) => isRenderable(o) && !isNamedOnItsOwn(o, options));
}

/** WorkflowSettings.boolean: YAML's own words, and nothing looser. */
export function fileBoolean(text: string): boolean | null {
  const lower = text.toLowerCase();
  if (lower === "true" || lower === "yes" || lower === "on") return true;
  if (lower === "false" || lower === "no" || lower === "off") return false;
  return null;
}

/** A boolean the file wrote as `yes` or `on` is the menu's `true`, not a value to mark. */
export function shown(value: string | undefined, option: ConfigOption): string | undefined {
  if (option.type !== "boolean" || value === undefined) return value;
  const flag = fileBoolean(value);
  return flag === null ? value : String(flag);
}

/** A boolean as a menu, because a switch cannot say "the runtime's default". */
export function selectable(option: ConfigOption): ConfigOption {
  if (option.type !== "boolean") return option;
  return { ...option, type: "select", options: [
    { value: "true", name: `${option.name} on` },
    { value: "false", name: `${option.name} off` },
  ] };
}

/** The option with a first choice that leaves the key out, named so three defaults differ. */
export function withDefault(option: ConfigOption, name: string): ConfigOption {
  const leading: ConfigChoiceGroup = { options: [{ value: null, name: `${name}: runtime default` }] };
  const groups: ConfigChoiceGroup[] = choiceGroups(option).map((g) => ({ ...(g.name ? { name: g.name } : {}), options: g.choices }));
  return { ...option, name, currentValue: null, options: [leading, ...groups] };
}

/** A chosen value as the file holds it: a string, or nothing for the default. */
export function fileValue(value: JSONValue): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function phrase(setting: string): string {
  switch (setting) {
    case "permission-mode": return "a permission mode";
    case "runtime": return "a runtime";
    case "model": return "a model";
    case "effort": return "an effort";
    default: return `a value for \`${setting}\` that`;
  }
}

/** WorkflowSettings.refusalDetail: why every fire is refused, naming what would work. */
export function refusalDetail(setting: string, value: string, offered: string[], runtime: string): string {
  if (!offered.length) {
    const what = ["permission-mode", "runtime", "model", "effort"].includes(setting) ? phrase(setting) : `an option called \`${setting}\``;
    return `${runtime} does not offer ${what} here at all`;
  }
  return `"${value}" is not ${phrase(setting)} ${runtime} offers here — it offers ${offered.join(", ")}`;
}

function offered(option: ConfigOption): string[] {
  return choices(option).map((c: ConfigChoice) => (typeof c.value === "string" ? c.value : c.name));
}

/** The window's `refusals`: each value the file names that the runtime does not offer here. */
export function refusals(settings: WorkflowSettings, remembered: readonly ConfigOption[], runtime: string): string[] {
  const others = otherOptions(remembered);
  const named: [string, string | undefined, ConfigOption | undefined][] = [
    ["permission-mode", settings.permissionMode, modeOption(remembered)],
    ["model", settings.model, modelOption(remembered)],
    ["effort", settings.effort, effortOption(remembered)],
    ...others.map((o): [string, string | undefined, ConfigOption] => [o.id, shown(settings.options[o.id], o), selectable(o)]),
  ];
  const lines = named
    .filter(([, value, option]) => value !== undefined && option !== undefined && !choices(option).some((c) => c.value === value))
    .map(([setting, value, option]) => refusalDetail(setting, value!, offered(option!), runtime));
  for (const id of Object.keys(settings.options).filter((id) => !others.some((o) => o.id === id)).sort()) {
    lines.push(`${id}: ${settings.options[id]} — ${runtime} does not offer this option here`);
  }
  return lines;
}

/** WorkflowWhenDone (#433): what a run may do with its session when it is done. */
export type WhenDone = WorkflowWhenDone;
export const whenDoneChoices: WhenDone[] = ["keep", "archive-allowed", "archive"];

/** WorkflowWhenDone.words: the menu's words for each. */
export function whenDoneWords(w: WhenDone): string {
  switch (w) {
    case "keep": return "Keep each run";
    case "archive-allowed": return "Let a run archive itself";
    case "archive": return "Archive each finished run";
  }
}

/** WorkflowWhenDone.sentence: what it means, under the menu. */
export function whenDoneSentence(w: WhenDone): string {
  switch (w) {
    case "keep": return "Every run stays in the list when it is done. A run may ask you to archive it.";
    case "archive-allowed": return "A run that finishes done or with nothing to do may archive itself when there is nothing to look at. Otherwise it stays.";
    case "archive": return "A run that finishes done or with nothing to do is archived. One that needs you, is stuck or is blocked stays.";
  }
}

/** The cooldown menu's lengths, in seconds; the file can say any other, which is added. */
export const cooldownChoices = [5, 15, 30, 60, 4 * 60, 24 * 60].map((m) => m * 60);

/** WorkflowCooldown.fileText: `15m`, `1h30m`, `1d`. */
export function cooldownFileText(seconds: number): string {
  let left = Math.floor(seconds / 60);
  const parts: string[] = [];
  for (const [unit, minutes] of [["d", 24 * 60], ["h", 60], ["m", 1]] as const) {
    if (left < minutes) continue;
    parts.push(`${Math.floor(left / minutes)}${unit}`);
    left %= minutes;
  }
  return parts.length ? parts.join("") : "0m";
}
