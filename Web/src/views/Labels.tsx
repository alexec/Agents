// A session's labels (071 FR-027; LabelTagField.swift): chips, each removable, and a field where
// a comma finishes a label and Delete on an empty field takes the last one off. What is typed is
// held to SessionLabelPolicy before it is sent; the project's labels are offered as you type.
// Above the prompt on the left, beside where it works, as in the window (#108); a new session
// keeps its labels until it starts, and starts with them.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Agent, SessionLabel } from "../protocol/generated";
import type { Store } from "../model/store";
import { accepted, maximumLabels, splitTyped } from "../model/labels";

/** The chips and the field, for whoever keeps the labels. */
export function LabelField({ store, host, folder, labels, add, remove, disabled, listID }: {
  store: Store; host: string; folder: string; labels: Pick<SessionLabel, "value" | "owner">[];
  add: (values: string[]) => void; remove: (value: string) => void; disabled: boolean; listID: string;
}) {
  const typed = useSignal("");
  const vocabulary = useSignal<string[]>([]);
  const existing = labels.map((l) => l.value);
  useEffect(() => {
    void store.labelVocabulary(host, folder).then((words) => (vocabulary.value = words));
  }, [host, folder, labels.length]);

  const take = (values: string[]) => {
    const taking = accepted(values, existing);
    if (taking.length) add(taking);
  };
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
        <input class="label-field" aria-label="Add a label" placeholder={labels.length ? "" : "Add labels"} list={listID}
          disabled={disabled} value={typed.value} size={labels.length ? 6 : 10}
          onInput={(e) => {
            const { finished, remainder } = splitTyped((e.currentTarget as HTMLInputElement).value);
            typed.value = remainder;
            if (finished.length) take(finished);
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && typed.value.trim()) {
              e.preventDefault();
              const value = typed.value;
              typed.value = "";
              take([value]);
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

/** An open session's labels, changed on the host as they are typed. */
export function Labels({ store, host, agent, folder, disabled }: {
  store: Store; host: string; agent: Agent; folder: string; disabled: boolean;
}) {
  return (
    <LabelField store={store} host={host} folder={folder} labels={agent.labels ?? []} disabled={disabled}
      listID={`labels-${agent.id}`}
      add={(values) => void store.setLabels(host, agent.id, values, [])}
      remove={(value) => void store.setLabels(host, agent.id, [], [value])} />
  );
}
