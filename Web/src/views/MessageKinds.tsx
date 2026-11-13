// The message components of the design system (docs/reference/design-system.md, "Messages"; #4740):
// a banner inset at the top of its pane, the one toast at the bottom of the viewport, and an alert in a
// `<dialog>` in place of `window.confirm`. A message never pushes the content that the person reads or
// types into: a banner moves it only when its condition starts or ends, a toast and an alert float.
import type { ComponentChildren } from "preact";
import { signal, useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import type { Store } from "../model/store";
import { undoLabel } from "../model/archiveWords";
import { alertButton, alertParts, toastMillis, toneGlyph, toneRole, type Tone } from "../model/messageKinds";
import { Glyph } from "./Icon";

/** The tone's icon: the tint is on the icon only, and it is never colour alone. */
export function ToneIcon({ tone }: { tone: Tone }) {
  return <span class={`message-icon tone-${tone}`} aria-hidden="true"><Glyph of={toneGlyph[tone]} /></span>;
}

/**
 * A banner: a condition of a pane or a page (offline, stale, a read that failed, a folder that has gone),
 * across the top of the pane, inset. It stays until the condition ends; the person cannot close it.
 * `name` keeps a pattern's own class beside the kind's, for the walks that look for it.
 */
export function MessageBanner({ tone, name, children, actions, busy }: {
  tone: Tone; name?: string; children: ComponentChildren; actions?: ComponentChildren; busy?: boolean;
}) {
  return (
    <div class={`message-banner tone-${tone}${name ? ` ${name}` : ""}`} role={toneRole(tone)}>
      {busy ? <span class="message-icon spinner" aria-hidden="true" /> : <ToneIcon tone={tone} />}
      <div class="message-words">{children}</div>
      {actions && <span class="message-actions">{actions}</span>}
    </div>
  );
}

/** What a toast shows: its words, at most two actions, and Close for one that stays. */
type ToastShown = {
  key: string; tone: Tone; words: string; name?: string;
  actions?: { words: string; run: () => void }[]; undo?: boolean; close: () => void;
};

/** The toast to show now, one at a time: an Undo first (Archive's, or another action's, #4793), then a failure, which waits under it. */
function shownToast(store: Store): ToastShown | null {
  const undo = store.archiveUndo.value;
  if (undo) {
    return {
      key: `undo-${undo.key}`, tone: "success", words: undo.line, name: "archive-undo", undo: true,
      actions: [{ words: undoLabel, run: () => void store.undoArchive() }],
      close: () => { if (store.archiveUndo.value?.key === undo.key) store.archiveUndo.value = null; },
    };
  }
  // Unarchive, Rename, the labels, Mute or Later (#4793): the same toast, and ⌘Z.
  const change = store.changeUndo.value;
  if (change) {
    return {
      key: `change-undo-${change.key}`, tone: "success", words: change.line, name: "change-undo", undo: true,
      actions: [{ words: undoLabel, run: () => void store.undoChange() }],
      close: () => { if (store.changeUndo.value?.key === change.key) store.changeUndo.value = null; },
    };
  }
  // A New Machine the provider refused opens its sheet again with the reason (#4634), not a toast.
  const problem = store.problem.value;
  if (problem) return { key: `problem-${problem}`, tone: "failure", words: problem, name: "problem", close: () => store.dismissProblem() };
  return null;
}

/**
 * The one toast, at the bottom centre of the viewport, above the prompt bar: the result of something the
 * person did now. A success goes after 4 seconds, one with Undo after 8, a failure stays until it is closed;
 * the time waits while the pointer or the focus is on it. ⌘Z (Ctrl+Z) is Undo while one shows, outside a
 * text field. The live region is always in the page, so a screen reader reads each toast as it comes.
 */
export function Toasts({ store }: { store: Store }) {
  const toast = shownToast(store);
  const hovering = useSignal(false);
  const focused = useSignal(false);
  const held = hovering.value || focused.value;
  // A toast that comes under the pointer gets no mouseleave: each one starts unheld.
  useEffect(() => { hovering.value = false; focused.value = false; }, [toast?.key]);
  useEffect(() => {
    if (!toast || held) return;
    const millis = toastMillis(toast.tone, toast.undo === true);
    if (millis === null) return;
    const timer = setTimeout(toast.close, millis);
    return () => clearTimeout(timer);
  }, [toast?.key, held]);
  useEffect(() => {
    if (!toast?.undo) return;
    const undo = toast.actions?.[0];
    const press = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() !== "z" || !(e.metaKey || e.ctrlKey) || e.shiftKey || e.altKey) return;
      const target = e.target as HTMLElement | null;
      if (target?.closest("input, textarea, [contenteditable=true]")) return;
      e.preventDefault();
      undo?.run();
    };
    document.addEventListener("keydown", press);
    return () => document.removeEventListener("keydown", press);
  }, [toast?.key]);
  // Above the prompt bar, whatever its height: the toast's foot is 12 px over the bar's top, or 24 px over
  // the viewport's foot when the page has no bar.
  const above = useSignal<number | null>(null);
  useLayoutEffect(() => {
    if (!toast) return;
    const place = () => {
      const bar = document.querySelector(".bar")?.getBoundingClientRect();
      above.value = bar && bar.height > 0 ? Math.max(24, innerHeight - bar.top + 12) : null;
    };
    place();
    addEventListener("resize", place);
    return () => removeEventListener("resize", place);
  }, [toast?.key]);
  return (
    <div class="toasts" aria-live="polite" aria-atomic="true" style={above.value === null ? undefined : { bottom: `${above.value}px` }}>
      {toast && (
        <div key={toast.key} class={`message-toast tone-${toast.tone}${toast.name ? ` ${toast.name}` : ""}`} role={toneRole(toast.tone)}
          onMouseEnter={() => { hovering.value = true; }} onMouseLeave={() => { hovering.value = false; }}
          onFocusIn={() => { focused.value = true; }} onFocusOut={() => { focused.value = false; }}>
          <ToneIcon tone={toast.tone} />
          <span class="message-words">{toast.words}</span>
          {toast.actions?.map((a) => <button key={a.words} type="button" class="link" onClick={a.run}>{a.words}</button>)}
          {toastMillis(toast.tone, toast.undo === true) === null
            && <button type="button" class="message-close" aria-label="Close" onClick={toast.close}>✕</button>}
        </div>
      )}
    </div>
  );
}

/** The alert being asked, and how it answers. */
type Asked = { title: string; detail: string | null; button: { label: string; destructive: boolean }; answer: (yes: boolean) => void };
const asked = signal<Asked[]>([]);

/**
 * Asks a choice that blocks the work, as `window.confirm` did, in the page's own `<dialog>`: the question,
 * its detail, Cancel and the question's verb. Answers true for the verb, false for Cancel or Escape.
 * `text` is the title, then a blank line or a question mark and the detail (alertParts).
 */
export function ask(text: string): Promise<boolean> {
  const { title, detail } = alertParts(text);
  return new Promise((resolve) => {
    asked.value = [...asked.value, { title, detail, button: alertButton(title), answer: resolve }];
  });
}

/** The page's alerts, one at a time, the first asked first. */
export function Alerts() {
  const now = asked.value[0];
  if (!now) return null;
  const answer = (yes: boolean) => {
    asked.value = asked.value.slice(1);
    now.answer(yes);
  };
  return <AlertDialog key={asked.value.length} asked={now} answer={answer} />;
}

function AlertDialog({ asked: a, answer }: { asked: Asked; answer: (yes: boolean) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const answered = useRef(false);
  const once = (yes: boolean) => {
    if (answered.current) return;
    answered.current = true;
    answer(yes);
  };
  useEffect(() => {
    const dialog = ref.current;
    if (dialog && !dialog.open) dialog.showModal();
    return () => dialog?.close();
  }, []);
  // A destructive verb is not the default: the focus starts on Cancel, as the platforms' alerts do.
  return (
    <dialog class="sheet message-alert" ref={ref} role="alertdialog" aria-labelledby="message-alert-title"
      aria-describedby={a.detail ? "message-alert-detail" : undefined} onClose={() => once(false)}>
      <h2 id="message-alert-title">{a.title}</h2>
      {a.detail && <p id="message-alert-detail" class="message-alert-detail">{a.detail}</p>}
      <div class="sheet-actions">
        <button type="button" autoFocus={a.button.destructive} onClick={() => once(false)}>Cancel</button>
        <button type="button" class={a.button.destructive ? "destructive" : "prominent"} autoFocus={!a.button.destructive}
          onClick={() => once(true)}>{a.button.label}</button>
      </div>
    </dialog>
  );
}
