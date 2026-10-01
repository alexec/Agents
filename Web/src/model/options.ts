// The prompt's menus: PromptControlsState.drawable, ConfigOption's rules (Model/Options.swift)
// and ModeMemory (Model/ModeMemory.swift), ported by hand and held to Fixtures/web/options.
import type { ConfigChoice, ConfigChoiceGroup, ConfigOption, JSONValue } from "../protocol/generated";

export const categoryOrder = ["mode", "model", "thought_level", "model_config", "permissions"];

function isGroup(item: ConfigChoice | ConfigChoiceGroup): item is ConfigChoiceGroup {
  return Array.isArray((item as ConfigChoiceGroup).options);
}

/** The choices in groups: one unnamed group for a flat list. */
export function choiceGroups(option: ConfigOption): { name?: string; choices: ConfigChoice[] }[] {
  const items = option.options ?? [];
  if (items.length && isGroup(items[0]!)) {
    return (items as ConfigChoiceGroup[]).map((g) => ({ ...(g.name ?? g.group ? { name: g.name ?? g.group } : {}), choices: g.options }));
  }
  return [{ choices: items as ConfigChoice[] }];
}

/** Every choice, groups flattened (ConfigOption.options). */
export function choices(option: ConfigOption): ConfigChoice[] {
  return choiceGroups(option).flatMap((g) => g.choices);
}

export function same(a: JSONValue | undefined, b: JSONValue | undefined): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

export function isRenderable(option: ConfigOption): boolean {
  if (option.type === "boolean") return true;
  if (option.type === "select") return choices(option).length > 0;
  return false;
}

export function categoryRank(option: ConfigOption): number {
  const index = option.category === undefined ? -1 : categoryOrder.indexOf(option.category);
  return index < 0 ? categoryOrder.length : index;
}

/** Permission sits apart from the rest: what the agent may do, not how well. */
export function isAboutPermission(option: ConfigOption): boolean {
  return option.category === "mode" || option.category === "permissions";
}

/** The options worth drawing, in order: the agent's own if it has any, else the draft's. */
export function drawable(agentOptions: readonly ConfigOption[] | undefined, draftOptions: readonly ConfigOption[]): ConfigOption[] {
  const source = agentOptions?.length ? agentOptions : draftOptions;
  return source.filter(isRenderable).map((option, index) => ({ option, index }))
    .sort((a, b) => categoryRank(a.option) - categoryRank(b.option) || a.index - b.index)
    .map(({ option }) => option);
}

/** What a closed menu reads: the choice's name, else the option's. */
export function closedTitle(option: ConfigOption, value?: JSONValue): string {
  const chosen = value ?? option.currentValue;
  return choices(option).find((c) => same(c.value, chosen))?.name ?? option.name;
}

/** The option that is the mode: by category first, by id second; never a switch. */
export function modeOption(options: readonly ConfigOption[]): ConfigOption | undefined {
  const selectable = options.filter((o) => o.type === "select");
  return selectable.find((o) => o.category === "mode") ?? selectable.find((o) => o.id === "mode");
}

/** What the mode opens on: the remembered value if still offered, else the runtime's current one. */
export function modeStartsOn(remembered: JSONValue | undefined, option: ConfigOption): JSONValue | undefined {
  if (remembered === undefined || !choices(option).some((c) => same(c.value, remembered))) return option.currentValue;
  return remembered;
}
