// A workflow's settings on its page (#162; the window's WorkflowPage form and the Remote's): the
// runtime a run will use and why (#2764), the permission mode on the left and the model, effort and the runtime's other options
// on the right, as the prompt's menus are laid out; then its labels, in the tag input sessions
// use; and, under the triggers, its cooldown, its hours (#4820) and what a run may do when done (#433). Each control writes its one key in the file through
// the daemon (`workflows/settings`) and is drawn from what the file says, so a refusal leaves the
// menu where the file is and the daemon's sentence beside it.
//
// The menus' choices are what the runtime last advertised in this folder (`options/remembered`),
// asked once per runtime and folder, not per change. Nothing remembered means the file's values
// are shown as text until the runtime has been used here, as the window does.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { ConfigOption, JSONValue, WorkflowHours, WorkflowSettings, WorkflowSummary } from "../protocol/generated";
import type { Store } from "../model/store";
import { modeOption } from "../model/options";
import {
  autoEffortNote, autoOption, cooldownChoices, cooldownFileText, effortOption, fileValue, modelOption, otherOptions, refusals, runsOn, selectable, shown, withDefault,
  whenDoneChoices, whenDoneWords, type WhenDone,
} from "../model/workflowSettings";
import { cooldownWords } from "../model/workflows";
import {
  admits, clockText, dayName, endingAt, halfHours, hoursWindow, hoursZones, inZone, limits, shownDays, startingAt, toggling, workingHours,
} from "../model/workflowHours";
import { labelKey } from "../model/labels";
import { OptionControl } from "./PromptMenus";
import { LabelField } from "./Labels";

type Change = Parameters<Store["setWorkflowSettings"]>[2];

/** A menu's choice as a change to the settings the file holds when it is sent. */
function writer(change: (change: Change) => void) {
  return (write: (s: WorkflowSettings, value: string | undefined) => WorkflowSettings) => (value: JSONValue) =>
    change({ settings: (s) => write(s, fileValue(value)) });
}

/** One of the keys the file names on its own, set, or taken out for the default. */
function without(s: WorkflowSettings, key: "permissionMode" | "model" | "effort", value: string | undefined): WorkflowSettings {
  const { [key]: _old, ...rest } = s;
  return (value === undefined ? rest : { ...rest, [key]: value }) as WorkflowSettings;
}

/** The menus, the labels and what went wrong, for one workflow. */
export function WorkflowSettingsForm({ store, host, summary, disabled, problem, change }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean;
  problem: string | null; change: (change: Change) => void;
}) {
  const workflow = summary.workflow;
  const settings = workflow.settings;
  const runs = runsOn(settings.runtimeID);
  const runtimeID = runs.runtimeID;
  const runtimes = (store.runtimes.value[host] ?? []).map((r) => r.runtime);
  const runtimeName = runtimes.find((r) => r.id === runtimeID)?.name ?? runtimeID;
  const remembered = useSignal<ConfigOption[] | null>(null);
  useEffect(() => {
    let current = true;
    remembered.value = null;
    void store.rememberedOptions(host, runtimeID, workflow.folder).then((options) => { if (current) remembered.value = options; });
    return () => { current = false; };
  }, [host, runtimeID, workflow.folder]);

  const set = writer(change);
  const known = remembered.value;
  const mode = known ? modeOption(known) : undefined;
  const model = known ? modelOption(known) : undefined;
  const effort = known ? effortOption(known) : undefined;
  const others = known ? otherOptions(known) : [];
  const triggering = workflow.mode === "triggering";
  const off = disabled || triggering;
  const notKnownYet = known !== null && <p class="quiet small">The choices are not known until {runtimeName} has been used in this folder.</p>;
  const marks = known ? refusals(settings, known, runtimeName) : [];

  return (
    <div class="workflow-settings">
      <p class="quiet small">{runs.line}</p>
      {runs.unknown && <p class="marked small">⚠︎ {runs.unknown}</p>}
      {triggering && <p class="quiet small">This workflow resumes the agent that triggered it, so these do not apply.</p>}
      {workflow.mode === "standing" && <p class="quiet small">Applied when its standing agent is started, and again if it has to be replaced.</p>}
      {runs.isAuto ? <AutoMenus settings={settings} disabled={off} set={set} /> : <>
      <div class="menus" role="group" aria-label="Settings for each run">
        {mode
          ? <OptionControl option={withDefault(mode, "Permission mode")} value={settings.permissionMode ?? null} disabled={off}
              onChange={set((s, v) => without(s, "permissionMode", v))} />
          : <span class="quiet small">Permission mode: {settings.permissionMode ?? "runtime default"}</span>}
        <span class="spacer" />
        <span class="menus-right">
          {model
            ? <OptionControl option={withDefault(model, "Model")} value={settings.model ?? null} disabled={off}
                onChange={set((s, v) => without(s, "model", v))} />
            : <span class="quiet small">Model: {settings.model ?? "runtime default"}</span>}
          {effort && <OptionControl option={withDefault(effort, "Effort")} value={settings.effort ?? null} disabled={off}
            onChange={set((s, v) => without(s, "effort", v))} />}
          {others.map((option) => (
            <OptionControl key={option.id} option={withDefault(selectable(option), option.name)}
              value={shown(settings.options[option.id], option) ?? null} disabled={off}
              onChange={set((s, v) => {
                const options = { ...s.options };
                if (v === undefined) delete options[option.id]; else options[option.id] = v;
                return { ...s, options };
              })} />
          ))}
        </span>
      </div>
      {(!mode || !model) && notKnownYet}
      {marks.map((line) => <p key={line} class="marked small">⚠︎ {line}</p>)}
      </>}
      <LabelField store={store} host={host} folder={workflow.folder} disabled={disabled}
        listID={`workflow-labels-${workflow.workflowID}`}
        labels={settings.labels.map((value) => ({ value, owner: "person" as const }))}
        add={(values) => change({ labels: (held) => [...held, ...values.filter((v) => !held.some((l) => labelKey(l) === labelKey(v)))] })}
        remove={(value) => change({ labels: (held) => held.filter((l) => labelKey(l) !== labelKey(value)) })} />
      {problem && <p class="marked small" role="alert">⚠︎ {problem}</p>}
    </div>
  );
}

/** On Auto, the permission mode and the model in the shared words (#2873), as the window's
 *  WorkflowPage.autoSettings: Auto picks the runtime each run, so it has no choices of its own. */
function AutoMenus({ settings, disabled, set }: {
  settings: WorkflowSettings; disabled: boolean; set: ReturnType<typeof writer>;
}) {
  const note = autoEffortNote(settings);
  return (
    <>
      <div class="menus" role="group" aria-label="Settings for each run">
        <OptionControl option={withDefault(autoOption("permission"), "Permission mode")} value={settings.permissionMode ?? null} disabled={disabled}
          onChange={set((s, v) => without(s, "permissionMode", v))} />
        <span class="spacer" />
        <span class="menus-right">
          <OptionControl option={withDefault(autoOption("model"), "Model")} value={settings.model ?? null} disabled={disabled}
            onChange={set((s, v) => without(s, "model", v))} />
        </span>
      </div>
      {note && <p class="quiet small">{note}</p>}
    </>
  );
}

/** The cooldown menu (#103): the lengths offered, and the file's own if it says another. */
export function CooldownMenu({ summary, disabled, change }: {
  summary: WorkflowSummary; disabled: boolean; change: (change: Change) => void;
}) {
  const current = summary.workflow.cooldown;
  const lengths = current === undefined || cooldownChoices.includes(current) ? cooldownChoices : [...cooldownChoices, current].sort((a, b) => a - b);
  const option: ConfigOption = {
    id: "cooldown", name: "Cooldown", type: "select", currentValue: null,
    options: [{ value: null, name: "No cooldown" }, ...lengths.map((l) => ({ value: l, name: `Cooldown: ${cooldownWords(l)}` }))],
  };
  return (
    <div class="menus" role="group" aria-label="Cooldown">
      <OptionControl option={option} value={current ?? null} disabled={disabled}
        onChange={(v) => change({ cooldown: typeof v === "number" ? cooldownFileText(v) : "" })} />
    </div>
  );
}

/** This browser's time zones, for the Hours menu. */
function knownZones(): string[] {
  const intl = Intl as unknown as { supportedValuesOf?: (key: string) => string[] };
  return intl.supportedValuesOf?.("timeZone") ?? [];
}

/**
 * When it may start (#4820): Any time, or a From and To time, days and a time zone, each
 * writing the whole `hours:` into the file, as the window's Hours control does. Any time
 * takes the key out.
 */
export function HoursSetting({ summary, disabled, change }: {
  summary: WorkflowSummary; disabled: boolean; change: (change: Change) => void;
}) {
  const current: WorkflowHours = summary.workflow.hours ?? {};
  const write = (h: WorkflowHours | null) => { if (h) change({ hours: h }); };
  const some = limits(current);
  const window = hoursWindow(current);
  const kind: ConfigOption = {
    id: "hours", name: "Hours", type: "select", currentValue: null,
    options: [{ value: false, name: "Any time" }, { value: true, name: "Some hours" }],
  };
  const from: ConfigOption = {
    id: "hours-from", name: "From", type: "select", currentValue: null,
    options: [{ value: null, name: "All day" }, ...halfHours.map((m) => ({ value: m, name: `From ${clockText(m)}` }))],
  };
  const to: ConfigOption = {
    id: "hours-to", name: "To", type: "select", currentValue: null,
    options: halfHours.filter((m) => m !== window?.from).map((m) => ({ value: m, name: `to ${clockText(m)}` })),
  };
  const zone: ConfigOption = {
    id: "hours-zone", name: "Time zone", type: "select", currentValue: null,
    options: [{ value: null, name: "Your time zone" }, ...hoursZones(current.timeZone, knownZones()).map((z) => ({ value: z, name: z }))],
  };
  return (
    <>
      <div class="menus" role="group" aria-label="Hours">
        <OptionControl option={kind} value={some} disabled={disabled}
          onChange={(v) => { if (v !== some) write(v === true ? workingHours : {}); }} />
        {some && (
          <>
            <OptionControl option={from} value={window?.from ?? null} disabled={disabled}
              onChange={(v) => write(startingAt(current, typeof v === "number" ? v : null))} />
            {window && (
              <OptionControl option={to} value={window.to} disabled={disabled}
                onChange={(v) => { if (typeof v === "number") write(endingAt(current, v)); }} />
            )}
            <OptionControl option={zone} value={current.timeZone ?? null} disabled={disabled}
              onChange={(v) => write(inZone(current, typeof v === "string" ? v : undefined))} />
          </>
        )}
      </div>
      {some && (
        <div class="menus" role="group" aria-label="Days">
          {shownDays.map((d) => {
            const on = admits(current, d);
            return (
              <button key={d} class={`pill${on ? " on" : ""}`} aria-pressed={on} disabled={disabled}
                title={on ? `Take ${dayName(d)} out of its hours` : `Put ${dayName(d)} in its hours`}
                onClick={() => write(toggling(current, d))}>{dayName(d)}</button>
            );
          })}
        </div>
      )}
    </>
  );
}

/** What a run may do with its session when it is done (#433), writing `when-done:`. */
export function WhenDoneMenu({ summary, disabled, change }: {
  summary: WorkflowSummary; disabled: boolean; change: (change: Change) => void;
}) {
  const current: WhenDone = summary.workflow.whenDone ?? "keep";
  const option: ConfigOption = {
    id: "when-done", name: "When done", type: "select", currentValue: null,
    options: whenDoneChoices.map((w) => ({ value: w, name: whenDoneWords(w) })),
  };
  return (
    <div class="menus" role="group" aria-label="When done">
      <OptionControl option={option} value={current} disabled={disabled}
        onChange={(v) => { if (typeof v === "string" && v !== current) change({ whenDone: v as WhenDone }); }} />
    </div>
  );
}
