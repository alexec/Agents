// A session's labels (071 FR-027; LabelTagField.swift): chips, each removable, and a field where
// a comma finishes a label and Delete on an empty field takes the last one off. What is typed is
// held to SessionLabelPolicy before it is sent; the folder's labels are offered as you type.
// Above the prompt on the left, beside where it works, as in the window (#108); a new session
// keeps its labels until it starts, and starts with them.
import { signal, useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Agent, SessionLabel } from "../protocol/generated";
import type { Store } from "../model/store";
import { accepted, labelKind, maximumLabels, splitTyped } from "../model/labels";

/** Below 760 the prompt's head is one line, as on the iPhone (#1107). */
const narrowQuery = typeof matchMedia === "function" ? matchMedia("(max-width: 759px)") : null;
const narrow = signal(narrowQuery?.matches ?? false);
narrowQuery?.addEventListener("change", (e) => { narrow.value = e.matches; });

/** The chips and the field, for whoever keeps the labels. */
export function LabelField({ store, host, folder, labels, add, remove, disabled, listID, focusFirst }: {
  store: Store; host: string; folder: string; labels: Pick<SessionLabel, "value" | "owner">[];
  add: (values: string[]) => void; remove: (value: string) => void; disabled: boolean; listID: string;
  /** Opened from the folded line: the field takes the focus at once. */
  focusFirst?: boolean;
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
    <div class="labels" role="group" aria-label="Labels" ref={group}>
      {labels.map((label) => (
        <span key={label.value} class={`chip label ${labelKind(label.value)}`} title={label.owner === "agent" ? "Added by the agent" : "Added by you"}>
          {label.value}
          <button class="remove" aria-label={`Remove the label ${label.value}`} disabled={disabled}
            onClick={() => {
              remove(label.value);
              // The chip goes, and the focus with it: back to the field, to type the next one.
              if (focusFirst) group.current?.querySelector<HTMLElement>(".label-field")?.focus();
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
// (#1107, the Remote's RemoteCompactLabelRow); a tap opens the whole field in a popover over the
// line, so the head stays one line and the chat does not move (#2173). A tap outside, Escape or
// Done closes it; each change applies as it is made.
export function Labels({ store, host, agent, folder, disabled }: {
  store: Store; host: string; agent: Agent; folder: string; disabled: boolean;
}) {
  const editing = useSignal(false);
  const anchor = useRef<HTMLSpanElement>(null);
  const labels = agent.labels ?? [];
  useEffect(() => {
    if (!editing.value) return;
    const close = (e: Event) => { if (!anchor.current?.contains(e.target as Node)) editing.value = false; };
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") editing.value = false; };
    addEventListener("pointerdown", close);
    addEventListener("keydown", escape);
    return () => { removeEventListener("pointerdown", close); removeEventListener("keydown", escape); };
  }, [editing.value]);
  const field = (focusFirst: boolean) => (
    <LabelField store={store} host={host} folder={folder} labels={labels} disabled={disabled}
      listID={`labels-${agent.id}`} focusFirst={focusFirst}
      add={(values) => void store.setLabels(host, agent.id, values, [])}
      remove={(value) => void store.setLabels(host, agent.id, [], [value])} />
  );
  if (!narrow.value) return field(false);
  const first = labels[0];
  const more = labels.length - 1;
  return (
    <span class="menu-anchor labels-anchor" ref={anchor}>
      <button class="labels-folded" disabled={disabled} aria-haspopup="dialog" aria-expanded={editing.value}
        onClick={() => (editing.value = !editing.value)}
        aria-label={labels.length ? `Labels: ${labels.map((l) => l.value).join(", ")}. Edit` : "Add label"}>
        {first ? <span class={`chip label ${labelKind(first.value)}`}>{first.value}</span> : <span class="add">+ Add label</span>}
        {more > 0 && <span class="more">+{more}</span>}
      </button>
      {editing.value && (
        <div class="popover up labels-popover" role="dialog" aria-label="Labels">
          {field(true)}
          <button class="done" onClick={() => (editing.value = false)}>Done</button>
        </div>
      )}
    </span>
  );
}
