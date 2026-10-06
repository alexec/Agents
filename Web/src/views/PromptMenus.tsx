// The menus under the prompt (071 FR-025; PromptBar.swift and OptionMenu.swift): what the runtime
// advertises, in the window's order, permission on the left and the rest on the right. Nothing
// here knows what a model or a mode is: the choices come from the runtime.
import type { ComponentChildren } from "preact";
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
export function PromptMenus({ options, value, onChange, disabled, besideMode, trailing }: {
  options: ConfigOption[]; value: (option: ConfigOption) => JSONValue | undefined;
  onChange: (option: ConfigOption, value: JSONValue) => void; disabled?: boolean | undefined;
  /** Beside the permission mode, as the window draws the command sandbox there (064). */
  besideMode?: ComponentChildren;
  trailing?: ComponentChildren;
}) {
  if (!options.length && !besideMode) return <div class="menus options-note">This runtime has nothing to adjust.</div>;
  const permission = options.filter(isAboutPermission);
  const others = options.filter((o) => !isAboutPermission(o));
  const control = (option: ConfigOption) => (
    <OptionControl key={option.id} option={option} value={value(option)} disabled={disabled}
      onChange={(v) => onChange(option, v)} />
  );
  return (
    <div class="menus" role="group" aria-label="Settings for this session">
      {permission.map(control)}
      {besideMode}
      {!options.length && <span class="options-note">This runtime has nothing to adjust.</span>}
      <span class="spacer" />
      {/* Together on the right, wrapping there rather than under the mode at phone width. */}
      {(others.length > 0 || trailing) && <span class="menus-right">{modelEffort(others, value, onChange, disabled)}{others.filter((o) => !isModelOrEffort(o)).map(control)}{trailing}</span>}
    </div>
  );
}

function isModelOrEffort(option: ConfigOption): boolean {
  return option.category === "model" || option.id === "model" || ["effort", "reasoning_effort", "thought_level"].includes(option.id);
}

/** The model and effort stay together behind one pill, as the Mac and Remote do. */
function modelEffort(options: ConfigOption[], value: (o: ConfigOption) => JSONValue | undefined,
  onChange: (o: ConfigOption, v: JSONValue) => void, disabled?: boolean) {
  const grouped = options.filter(isModelOrEffort);
  if (!grouped.length) return null;
  const title = grouped.map((o) => closedTitle(o, value(o))).join(" · ");
  return <details class="model-effort"><summary class="pill" aria-label={`Model and effort: ${title}`}>{title}</summary>
    <div class="model-effort-menu" role="group" aria-label="Model and effort">{grouped.map((option) => <OptionControl key={option.id} option={option}
      value={value(option)} disabled={disabled} onChange={(v) => onChange(option, v)} />)}</div>
  </details>;
}
