// A session's labels (071 FR-027; LabelTagField.swift): chips, each removable, and a field where
// a comma finishes a label and Delete on an empty field takes the last one off. What is typed is
// held to SessionLabelPolicy before it is sent; the project's labels are offered as you type.
// Above the prompt on the left, beside where it works, as in the window (#108); a new session
// keeps its labels until it starts, and starts with them.
import { signal, useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Agent, SessionLabel } from "../protocol/generated";
import type { Store } from "../model/store";
import { accepted, maximumLabels, splitTyped } from "../model/labels";

/** Below 760 the prompt's head is one line, as on the iPhone (#1107). */
const narrowQuery = typeof matchMedia === "function" ? matchMedia("(max-width: 759px)") : null;
const narrow = signal(narrowQuery?.matches ?? false);
narrowQuery?.addEventListener("change", (e) => { narrow.value = e.matches; });

/** The chips and the field, for whoever keeps the labels. */
export function LabelField({ store, host, folder, labels, add, remove, disabled, listID, focusFirst, onLeave }: {
  store: Store; host: string; folder: string; labels: Pick<SessionLabel, "value" | "owner">[];
  add: (values: string[]) => void; remove: (value: string) => void; disabled: boolean; listID: string;
  /** Opened from the folded line: the field takes the focus at once. */
  focusFirst?: boolean;
  /** Called when the focus leaves the chips and the field. */
  onLeave?: (() => void) | undefined;
}) {
  const group = useRef<HTMLDivElement>(null);
  const typed = useSignal("");
  const vocabulary = useSignal<string[]>([]);
  const existing = labels.map((l) => l.value);
  useEffect(() => {
    if (!focusFirst) return;
    (group.current?.querySelector<HTMLElement>(".label-field") ?? group.current)?.focus();
  }, []);
  useEffect(() => {
    void store.labelVocabulary(host, folder).then((words) => (vocabulary.value = words));
  }, [host, folder, labels.length]);

  const take = (values: string[]) => {
    const taking = accepted(values, existing);
    if (taking.length) add(taking);
  };
  return (
    <div class="labels" role="group" aria-label="Labels" ref={group} tabIndex={onLeave ? -1 : undefined}
      onFocusOut={onLeave && ((e) => {
        if (!group.current?.contains(e.relatedTarget as Node | null)) onLeave();
      })}>
      {labels.map((label) => (
        <span key={label.value} class="chip label" title={label.owner === "agent" ? "Added by the agent" : "Added by you"}>
          {label.value}
          <button class="remove" aria-label={`Remove the label ${label.value}`} disabled={disabled}
            onClick={() => {
              remove(label.value);
              // The chip goes, and the focus with it: back to the field, so the open line stays open.
              if (onLeave) (group.current?.querySelector<HTMLElement>(".label-field") ?? group.current)?.focus();
            }}>×</button>
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
// Below 760 they fold to one line, the first label and +N for the rest, or Add label with none
// (#1107, the Remote's RemoteCompactLabelRow); a tap opens the whole field in place, and it folds
// again when the focus leaves it.
export function Labels({ store, host, agent, folder, disabled }: {
  store: Store; host: string; agent: Agent; folder: string; disabled: boolean;
}) {
  const editing = useSignal(false);
  const labels = agent.labels ?? [];
  if (narrow.value && !editing.value) {
    const first = labels[0];
    const more = labels.length - 1;
    return (
      <button class="labels-folded" disabled={disabled} onClick={() => (editing.value = true)}
        aria-label={labels.length ? `Labels: ${labels.map((l) => l.value).join(", ")}. Edit` : "Add label"}>
        {first ? <span class="chip label">{first.value}</span> : <span class="add">+ Add label</span>}
        {more > 0 && <span class="more">+{more}</span>}
      </button>
    );
  }
  return (
    <LabelField store={store} host={host} folder={folder} labels={labels} disabled={disabled}
      listID={`labels-${agent.id}`}
      focusFirst={editing.value} onLeave={narrow.value ? () => (editing.value = false) : undefined}
      add={(values) => void store.setLabels(host, agent.id, values, [])}
      remove={(value) => void store.setLabels(host, agent.id, [], [value])} />
  );
}
