// A workflow's settings on its page (#162; the window's WorkflowPage form and the Remote's): the
// runtime, the permission mode on the left and the model, effort and the runtime's other options
// on the right, as the prompt's menus are laid out; then its labels, in the tag input sessions
// use; and, under the triggers, its cooldown. Each control writes its one key in the file through
// the daemon (`workflows/settings`) and is drawn from what the file says, so a refusal leaves the
// menu where the file is and the daemon's sentence beside it.
//
// The menus' choices are what the runtime last advertised in this folder (`options/remembered`),
// asked once per runtime and folder, not per change. Nothing remembered means the file's values
// are shown as text until the runtime has been used here, as the window does.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { ConfigOption, JSONValue, WorkflowSettings, WorkflowSummary } from "../protocol/generated";
import type { Store } from "../model/store";
import { modeOption } from "../model/options";
import { defaultRuntime } from "../model/workflows";
import {
  cooldownChoices, cooldownFileText, effortOption, fileValue, modelOption, otherOptions, refusals, selectable, shown, withDefault,
} from "../model/workflowSettings";
import { cooldownWords } from "../model/workflows";
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
function without(s: WorkflowSettings, key: "permissionMode" | "runtimeID" | "model" | "effort", value: string | undefined): WorkflowSettings {
  const { [key]: _old, ...rest } = s;
  return (value === undefined ? rest : { ...rest, [key]: value }) as WorkflowSettings;
}

/**
 * The file top left and the runtime top right, above the prompt, as the window has them. The
 * runtimes are the ones this host has; a value it does not know is shown and marked, because
 * that workflow is refusing every fire on it.
 */
export function RuntimeRow({ store, host, summary, disabled, change }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; change: (change: Change) => void;
}) {
  const workflow = summary.workflow;
  const named = workflow.settings.runtimeID;
  const runtimes = (store.runtimes.value[host] ?? []).map((r) => r.runtime);
  const option: ConfigOption = {
    id: "runtime", name: "Runtime", type: "select", currentValue: null,
    options: [
      { value: null, name: `Default (${runtimes.find((r) => r.id === defaultRuntime)?.name ?? defaultRuntime})` },
      ...runtimes.map((r) => ({ value: r.id, name: r.name })),
    ],
  };
  return (
    <>
      <div class="menus file-and-runtime" role="group" aria-label="Runtime">
        <span class="quiet small">.agents/workflows/{workflow.workflowID}.md</span>
        <span class="spacer" />
        <OptionControl option={option} value={named ?? null} disabled={disabled}
          onChange={writer(change)((s, v) => without(s, "runtimeID", v))} />
      </div>
      {named !== undefined && runtimes.length > 0 && !runtimes.some((r) => r.id === named) && (
        <p class="marked small">⚠︎ "{named}" is not a runtime this host knows</p>
      )}
    </>
  );
}

/** The menus, the labels and what went wrong, for one workflow. */
export function WorkflowSettingsForm({ store, host, summary, disabled, problem, change }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean;
  problem: string | null; change: (change: Change) => void;
}) {
  const workflow = summary.workflow;
  const settings = workflow.settings;
  const runtimeID = settings.runtimeID ?? defaultRuntime;
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
  const notKnownYet = known !== null && <p class="quiet small">The choices are not known until {runtimeName} has been used in this project.</p>;
  const marks = known ? refusals(settings, known, runtimeName) : [];

  return (
    <div class="workflow-settings">
      {triggering && <p class="quiet small">This workflow resumes the agent that triggered it, so these do not apply.</p>}
      {workflow.mode === "standing" && <p class="quiet small">Applied when its standing agent is started, and again if it has to be replaced.</p>}
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
      <LabelField store={store} host={host} folder={workflow.folder} disabled={disabled}
        listID={`workflow-labels-${workflow.workflowID}`}
        labels={settings.labels.map((value) => ({ value, owner: "person" as const }))}
        add={(values) => change({ labels: (held) => [...held, ...values.filter((v) => !held.some((l) => labelKey(l) === labelKey(v)))] })}
        remove={(value) => change({ labels: (held) => held.filter((l) => labelKey(l) !== labelKey(value)) })} />
      {problem && <p class="marked small" role="alert">⚠︎ {problem}</p>}
    </div>
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
