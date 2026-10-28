// The menus under the prompt (071 FR-025; PromptBar.swift and OptionMenu.swift): what the runtime
// advertises, in the window's order, permission on the left and the rest on the right. Nothing
// here knows what a model or a mode is: the choices come from the runtime.
import type { ComponentChildren } from "preact";
import { useState } from "preact/hooks";
import type { ClientPermissionSettings, ConfigOption, JSONValue } from "../protocol/generated";
import { choiceGroups, closedTitle, isAboutPermission, same } from "../model/options";
import { nothingToAdjust } from "../model/promptWords";
import { line } from "../model/orgPolicy";
import { optionLabel } from "./OrgPolicyLine";

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
            // A mode or model the organisation refuses: shown, dimmed, not chosen (#998, FR-020).
            <option key={offset + i} value={String(offset + i)} disabled={c.setBy !== undefined}
              title={c.setBy ? line(c.setBy) : c.description ?? ""}>{optionLabel(c.name, c.setBy)}</option>
          ));
          return group.name ? <optgroup key={g} label={group.name}>{items}</optgroup> : items;
        })}
      </select>
    </label>
  );
}

/** Every drawn option: permission first, then the rest, as the window lays them out. */
export function PromptMenus({ options, value, onChange, disabled, runtime, runtimeID, clientPermissionMode,
  onClientPermissionModeChange, besideMode, trailing }: {
  options: ConfigOption[]; value: (option: ConfigOption) => JSONValue | undefined;
  onChange: (option: ConfigOption, value: JSONValue) => void; disabled?: boolean | undefined;
  /** The runtime's name, as the note says it when it offers nothing. */
  runtime?: string | undefined;
  runtimeID?: string | undefined;
  clientPermissionMode?: ClientPermissionSettings["cursor"] | undefined;
  onClientPermissionModeChange?: ((mode: ClientPermissionSettings["cursor"]) => void) | undefined;
  /** Beside the permission mode, as the window draws the command sandbox there (064). */
  besideMode?: ComponentChildren;
  trailing?: ComponentChildren;
}) {
  if (!options.length && !besideMode) return <div class="menus options-note">{nothingToAdjust(runtime)}</div>;
  const permission = options.filter(isAboutPermission);
  const others = options.filter((o) => !isAboutPermission(o));
  const control = (option: ConfigOption) => (
    <OptionControl key={option.id} option={option} value={value(option)} disabled={disabled}
      onChange={(v) => onChange(option, v)} />
  );
  return (
    <div class="menus" role="group" aria-label="Settings for this session">
      {runtimeID && ["cursor", "grok", "opencode"].includes(runtimeID) && onClientPermissionModeChange &&
        <ClientPermissionControl runtime={runtime ?? runtimeID}
          mode={clientPermissionMode ?? "default"} onChange={onClientPermissionModeChange}
          disabled={disabled ?? false} />}
      {permission.map(control)}
      {besideMode}
      {!options.length && <span class="options-note">{nothingToAdjust(runtime)}</span>}
      <span class="spacer" />
      {/* Together on the right, wrapping there rather than under the mode at phone width. */}
      {(others.length > 0 || trailing) && <span class="menus-right">{modelEffort(others, value, onChange, disabled)}{others.filter((o) => !isModelOrEffort(o)).map(control)}{trailing}</span>}
    </div>
  );
}

function ClientPermissionControl({ runtime, mode, onChange, disabled }: {
  runtime: string; mode: ClientPermissionSettings["cursor"];
  onChange: (mode: ClientPermissionSettings["cursor"]) => void; disabled?: boolean;
}) {
  // Always-approve answers every request for every agent of the runtime: one more click (#2746).
  const [confirming, setConfirming] = useState(false);
  const title = (choice: ClientPermissionSettings["cursor"]) => choice === "alwaysApprove" ? "Always-approve" : "Default";
  const choices: ClientPermissionSettings["cursor"][] = ["default", "alwaysApprove"];
  const scope = `Applies to every ${runtime} agent, including workflows and server folders.`;
  const description = (choice: ClientPermissionSettings["cursor"]) => choice === "default"
    ? `Asks before ${runtime} does something that needs permission.`
    : "Answers every permission request for you. Questions that are not permission still wait.";
  const close = () => {
    setConfirming(false);
    const details = document.activeElement?.closest("details");
    if (details instanceof HTMLDetailsElement) details.open = false;
  };
  return (
    <details class="client-permission-control" onToggle={(e) => {
      if (!(e.currentTarget as HTMLDetailsElement).open) setConfirming(false);
    }}>
      {/* What it sets, then its value: beside the sandbox pill, "Default" alone says nothing. */}
      <summary class="pill" title={`${runtime} permissions. ${scope}`}
        aria-label={`${runtime} permissions: ${title(mode)}`} aria-disabled={disabled}>
        Permissions: {title(mode)} <span aria-hidden="true">▾</span>
      </summary>
      <div class="client-permission-menu" role="group" aria-label={`${runtime} permissions`}>
        {confirming ? (
          <div class="client-permission-confirm" role="alertdialog"
            aria-label={`Always approve every ${runtime} permission request?`}>
            <p>Always approve every {runtime} permission request?</p>
            <p class="quiet small">No {runtime} agent, workflow or server folder will ask before it edits files or runs commands. Set Default to make them ask again.</p>
            <div class="client-permission-actions">
              <button type="button" onClick={close}>Cancel</button>
              <button type="button" class="destructive" disabled={disabled} onClick={() => {
                onChange("alwaysApprove");
                close();
              }}>Always Approve</button>
            </div>
          </div>
        ) : (<>
          {choices.map((choice) => (
            <button type="button" key={choice} class="client-permission-choice" disabled={disabled}
              aria-pressed={mode === choice} title={description(choice)} onClick={() => {
                if (choice === "alwaysApprove" && mode !== "alwaysApprove") {
                  setConfirming(true);
                  return;
                }
                onChange(choice);
                close();
              }}>
              <span class="client-permission-title"><span aria-hidden="true">{mode === choice ? "✓" : " "}</span>
                {title(choice)}</span>
              <span class="quiet small">{description(choice)}</span>
            </button>
          ))}
          <p class="quiet small">{scope}</p>
        </>)}
      </div>
    </details>
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
