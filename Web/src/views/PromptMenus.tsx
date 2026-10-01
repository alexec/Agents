// The menus under the prompt (071 FR-025; PromptBar.swift and OptionMenu.swift): what the runtime
// advertises, in the window's order, permission on the left and the rest on the right. Nothing
// here knows what a model or a mode is: the choices come from the runtime.
import type { ConfigOption, JSONValue } from "../protocol/generated";
import { choiceGroups, closedTitle, isAboutPermission, same } from "../model/options";

export function OptionControl({ option, value, onChange, disabled }: {
  option: ConfigOption; value: JSONValue | undefined; onChange: (value: JSONValue) => void; disabled?: boolean | undefined;
}) {
  const chosen = value ?? option.currentValue;
  if (option.type === "boolean") {
    const on = chosen === true;
    return (
      <button class={`pill${on ? " on" : ""}`} aria-pressed={on} disabled={disabled} title={option.description ?? option.name}
        onClick={() => onChange(!on)}>{option.name}</button>
    );
  }
  const groups = choiceGroups(option);
  const index = groups.flatMap((g) => g.choices).findIndex((c) => same(c.value, chosen));
  const flat = groups.flatMap((g) => g.choices);
  return (
    <label class="pill select" title={option.description ?? option.name}>
      <span class="visually-hidden">{option.name}</span>
      <span aria-hidden="true">{closedTitle(option, chosen)} ▾</span>
      <select aria-label={option.name} disabled={disabled} value={index < 0 ? "" : String(index)}
        onChange={(e) => {
          const picked = flat[Number((e.currentTarget as HTMLSelectElement).value)];
          if (picked) onChange(picked.value);
        }}>
        {index < 0 && <option value="" disabled>{closedTitle(option, chosen)}</option>}
        {groups.map((group, g) => {
          const offset = groups.slice(0, g).reduce((n, x) => n + x.choices.length, 0);
          const items = group.choices.map((c, i) => (
            <option key={offset + i} value={String(offset + i)} title={c.description ?? ""}>{c.name}</option>
          ));
          return group.name ? <optgroup key={g} label={group.name}>{items}</optgroup> : items;
        })}
      </select>
    </label>
  );
}

/** Every drawn option: permission first, then the rest, as the window lays them out. */
export function PromptMenus({ options, value, onChange, disabled }: {
  options: ConfigOption[]; value: (option: ConfigOption) => JSONValue | undefined;
  onChange: (option: ConfigOption, value: JSONValue) => void; disabled?: boolean | undefined;
}) {
  if (!options.length) return null;
  const permission = options.filter(isAboutPermission);
  const others = options.filter((o) => !isAboutPermission(o));
  const control = (option: ConfigOption) => (
    <OptionControl key={option.id} option={option} value={value(option)} disabled={disabled}
      onChange={(v) => onChange(option, v)} />
  );
  return (
    <div class="menus" role="group" aria-label="Settings for this session">
      {permission.map(control)}
      <span class="spacer" />
      {others.map(control)}
    </div>
  );
}
