// The menus under the prompt (071 FR-025; PromptBar.swift and OptionMenu.swift): what the runtime
// advertises, in the window's order, permission on the left and the rest on the right. Nothing
// here knows what a model or a mode is: the choices come from the runtime.
import type { ComponentChildren } from "preact";
import { useState } from "preact/hooks";
import type { AutoField, AutoMapping, ClientPermissionSettings, ConfigOption, JSONValue } from "../protocol/generated";
import { choiceGroups, closedTitle, isAboutPermission, same } from "../model/options";
import { nothingToAdjust } from "../model/promptWords";
import { line } from "../model/orgPolicy";
import { optionLabel } from "./OrgPolicyLine";
import { customWords, fieldWords, followsSettings, levelMeaning, levelWords, levelsOf, markWords, ownWords } from "../model/levels";

type Mode = ClientPermissionSettings["cursor"];

/** The shared words on a runtime (#2658): the value in force for a field, each value's cell on
 *  the runtime, and what choosing one does. */
export type LevelProps = {
  runtimeName?: string | undefined;
  chosen: (field: "model" | "permission") => string | undefined;
  cell: (field: AutoField, level: string) => AutoMapping | undefined;
  choose: (field: "model" | "permission", level: string) => void;
};

/** The agent's own answer to permission requests, else Settings' (#2658, FR-019). */
export type ClientPermissionProps = {
  own: Mode | undefined; settings: Mode; set: (mode: Mode | undefined) => void;
};

/**
 * The Model or Permission mode pill (#2658): the value alone, or Custom where the runtime's own
 * setting matches none; each value says what it is on the runtime; the runtime's own choices
 * behind ⋯ <runtime>'s own, which Auto has none of.
 */
export function LevelSelect({ field, levels, own, value, onChange, disabled }: {
  field: "model" | "permission"; levels: LevelProps; own: ConfigOption[];
  value?: ((option: ConfigOption) => JSONValue | undefined) | undefined;
  onChange?: ((option: ConfigOption, value: JSONValue) => void) | undefined; disabled?: boolean | undefined;
}) {
  const chosen = levels.chosen(field);
  const title = chosen ? levelWords(field, chosen) : customWords;
  const close = (e: Event) => {
    const details = (e.currentTarget as HTMLElement).closest("details");
    if (details) details.open = false;
  };
  return (
    <details class="level-select model-effort">
      <summary class="pill" aria-label={`${fieldWords[field]}: ${title}`} aria-disabled={disabled}>{title} <span aria-hidden="true">▾</span></summary>
      <div class="model-effort-menu" role="group" aria-label={fieldWords[field]}>
        <p class="quiet small">{fieldWords[field]}</p>
        {levelsOf(field).map((level) => {
          const cell = levels.cell(field, level);
          const cannot = cell?.mark === "notPossible" || cell?.mark === "dropped";
          const line = cell ? (cannot ? [markWords[cell.mark], cell.note].filter(Boolean).join(": ")
            : `${cell.words}${levels.runtimeName ? ` on ${levels.runtimeName}` : ""}`) : levelMeaning(field, level);
          return (
            <button type="button" key={level} class="client-permission-choice" disabled={disabled || cannot}
              aria-pressed={chosen === level} onClick={(e) => { levels.choose(field, level); close(e); }}>
              <span class="client-permission-title"><span aria-hidden="true">{chosen === level ? "✓" : " "}</span>
                {levelWords(field, level)}</span>
              <span class="quiet small">{line}</span>
            </button>
          );
        })}
        {own.length > 0 && value && onChange && levels.runtimeName && (
          <details class="level-own">
            <summary class="quiet small">{ownWords(levels.runtimeName)}</summary>
            {own.map((option) => <OptionControl key={option.id} option={option} value={value(option)} disabled={disabled}
              onChange={(v) => onChange(option, v)} />)}
          </details>
        )}
      </div>
    </details>
  );
}

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
export function PromptMenus({ options, value, onChange, disabled, runtime, runtimeID, clientPermission,
  besideMode, trailing, levels }: {
  options: ConfigOption[]; value: (option: ConfigOption) => JSONValue | undefined;
  onChange: (option: ConfigOption, value: JSONValue) => void; disabled?: boolean | undefined;
  /** The runtime's name, as the note says it when it offers nothing. */
  runtime?: string | undefined;
  runtimeID?: string | undefined;
  clientPermission?: ClientPermissionProps | undefined;
  /** The shared words for the model and the permission mode (#2658). */
  levels?: LevelProps | undefined;
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
      {levels && (permission.length > 0 || levels.cell("permission", "ask")?.native)
        ? <LevelSelect field="permission" levels={levels} own={permission} value={value} onChange={onChange} disabled={disabled} />
        : permission.map(control)}
      {runtimeID && ["cursor", "grok", "opencode"].includes(runtimeID) && clientPermission &&
        <ClientPermissionControl runtime={runtime ?? runtimeID} own={clientPermission.own}
          settings={clientPermission.settings} onChange={clientPermission.set} disabled={disabled ?? false} />}
      {besideMode}
      {!options.length && <span class="options-note">{nothingToAdjust(runtime)}</span>}
      <span class="spacer" />
      {/* Together on the right, wrapping there rather than under the mode at phone width. */}
      {(others.length > 0 || trailing) && <span class="menus-right">{levels && others.some(isModelOrEffort)
        ? <LevelSelect field="model" levels={levels} own={others.filter(isModelOrEffort)} value={value} onChange={onChange} disabled={disabled} />
        : modelEffort(others, value, onChange, disabled)}{others.filter((o) => !isModelOrEffort(o)).map(control)}{trailing}</span>}
    </div>
  );
}

function ClientPermissionControl({ runtime, own, settings, onChange, disabled }: {
  runtime: string; own: Mode | undefined; settings: Mode;
  onChange: (mode: Mode | undefined) => void; disabled?: boolean;
}) {
  const mode = own ?? settings;
  // The value Settings gives, chosen again, follows Settings still.
  const pick = (choice: Mode) => onChange(own === undefined && choice === settings ? undefined : choice);
  // Always-approve answers every request for every agent of the runtime: one more click (#2746).
  const [confirming, setConfirming] = useState(false);
  // In the words every runtime shares (#2658): Request cards or Yes to all.
  const title = (choice: ClientPermissionSettings["cursor"]) => levelWords("permissionRequests", choice);
  const choices: ClientPermissionSettings["cursor"][] = ["default", "alwaysApprove"];
  const scope = `For this agent. Settings ▸ Agent Runtimes ▸ ${runtime} gives every new one its value.`;
  const description = (choice: ClientPermissionSettings["cursor"]) => levelMeaning("permissionRequests", choice);
  const close = () => {
    setConfirming(false);
    const details = document.activeElement?.closest("details");
    if (details instanceof HTMLDetailsElement) details.open = false;
  };
  return (
    <details class="client-permission-control" onToggle={(e) => {
      if (!(e.currentTarget as HTMLDetailsElement).open) setConfirming(false);
    }}>
      {/* The value alone, as every pill says (#2658); the menu's header names the field. */}
      <summary class="pill" title={`${fieldWords.permissionRequests}. ${scope}`}
        aria-label={`${runtime} permission requests: ${title(mode)}`} aria-disabled={disabled}>
        {title(mode)} <span aria-hidden="true">▾</span>
      </summary>
      <div class="client-permission-menu" role="group" aria-label={`${runtime} permission requests`}>
        {confirming ? (
          <div class="client-permission-confirm" role="alertdialog"
            aria-label={`Say yes to every permission request of this ${runtime} agent?`}>
            <p>Say yes to every permission request of this {runtime} agent?</p>
            <p class="quiet small">It will not ask before it edits files or runs commands. Choose Request cards to make it ask again.</p>
            <div class="client-permission-actions">
              <button type="button" onClick={close}>Cancel</button>
              <button type="button" class="destructive" disabled={disabled} onClick={() => {
                pick("alwaysApprove");
                close();
              }}>Yes to All</button>
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
                pick(choice);
                close();
              }}>
              <span class="client-permission-title"><span aria-hidden="true">{mode === choice ? "✓" : " "}</span>
                {title(choice)}{own === undefined && choice === settings ? <span class="quiet"> {followsSettings}</span> : null}</span>
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
