// A session's labels (071 FR-027; LabelTagField.swift): chips, each removable, and a field where
// a comma finishes a label and Delete on an empty field takes the last one off. What is typed is
// held to SessionLabelPolicy before it is sent; the project's labels are offered as you type.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { accepted, maximumLabels, splitTyped } from "../model/labels";

export function Labels({ store, host, agent, folder, disabled }: {
  store: Store; host: string; agent: Agent; folder: string; disabled: boolean;
}) {
  const typed = useSignal("");
  const vocabulary = useSignal<string[]>([]);
  const labels = agent.labels ?? [];
  const existing = labels.map((l) => l.value);
  useEffect(() => {
    void store.labelVocabulary(host, folder).then((words) => (vocabulary.value = words));
  }, [host, folder, labels.length]);

  const add = async (values: string[]) => {
    const taking = accepted(values, existing);
    if (taking.length) await store.setLabels(host, agent.id, taking, []);
  };
  const remove = (value: string) => void store.setLabels(host, agent.id, [], [value]);
  const listID = `labels-${agent.id}`;
  return (
    <div class="labels" role="group" aria-label="Labels">
      {labels.map((label) => (
        <span key={label.value} class="chip label" title={label.owner === "agent" ? "Added by the agent" : "Added by you"}>
          {label.value}
          <button class="remove" aria-label={`Remove the label ${label.value}`} disabled={disabled}
            onClick={() => remove(label.value)}>×</button>
        </span>
      ))}
      {labels.length < maximumLabels && (
        <input class="label-field" aria-label="Add a label" placeholder={labels.length ? "" : "Add a label"} list={listID}
          disabled={disabled} value={typed.value}
          onInput={(e) => {
            const { finished, remainder } = splitTyped((e.currentTarget as HTMLInputElement).value);
            typed.value = remainder;
            if (finished.length) void add(finished);
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && typed.value.trim()) {
              e.preventDefault();
              const value = typed.value;
              typed.value = "";
              void add([value]);
            } else if (e.key === "Backspace" && typed.value === "" && labels.length) {
              remove(labels[labels.length - 1]!.value);
            }
          }} />
      )}
      <datalist id={listID}>
        {vocabulary.value.filter((w) => !existing.some((x) => x.toLowerCase() === w.toLowerCase())).map((w) => <option key={w} value={w} />)}
      </datalist>
    </div>
  );
}
