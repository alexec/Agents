// A file that is not a page, open for typing (#415), as the window's SourceEditor: its source in
// the code face, saved through artifact/write a moment after the typing stops and when the field
// is left. While nothing typed is waiting to be saved, a change on disk is taken in place; while
// something is, the person's text wins and is written over it.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import type { Store } from "../../model/store";
import { nameOf } from "./paneState";

const settle = 700;

/** Where a line starts in a text, counted from one. Past the end is the end. */
export function offsetOfLine(text: string, line: number): number {
  let offset = 0;
  for (let number = 1; number < line; number++) {
    const next = text.indexOf("\n", offset);
    if (next < 0) return text.length;
    offset = next + 1;
  }
  return offset;
}

export function SourceEditor({ store, host, agentID, path, text, line }: {
  store: Store; host: string; agentID: string; path: string; text: string; line?: number | undefined;
}) {
  const draft = useSignal(text);
  const saved = useRef(text);
  const failed = useSignal(false);
  const saving = useRef<ReturnType<typeof setTimeout> | null>(null);
  const field = useRef<HTMLTextAreaElement>(null);
  const canEdit = store.link.state.kind === "open" && store.hostIsOnline(host);

  // The file changed on disk: taken in place unless something typed is still to be saved.
  useEffect(() => {
    if (draft.peek() === saved.current) draft.value = text;
    saved.current = text;
  }, [text]);

  useLayoutEffect(() => {
    const el = field.current;
    if (!el || !line) return;
    const at = offsetOfLine(el.value, line);
    el.setSelectionRange(at, at);
    // Roughly where the line is, then the browser keeps the caret in view as it moves.
    const lineHeight = parseFloat(getComputedStyle(el).lineHeight) || 18;
    el.scrollTop = Math.max(0, (line - 1) * lineHeight - el.clientHeight / 2);
  }, [path, line]);

  const save = async () => {
    if (saving.current) { clearTimeout(saving.current); saving.current = null; }
    const sending = draft.peek();
    if (sending === saved.current) return;
    const ok = await store.writeArtifact(host, agentID, path, sending);
    failed.value = !ok;
    if (ok) saved.current = sending;
  };

  // Left with something unsaved — Back, another file, the pane shut: written now.
  useEffect(() => () => { void save(); }, [path]);

  return (
    <>
      {failed.value && <p class="hint">{nameOf(path)} could not be saved. What you typed is kept here.</p>}
      <textarea ref={field} class="file-text source-editor" aria-label={`Editing ${nameOf(path)}`}
        spellcheck={false} autocapitalize="off" autocomplete="off" readOnly={!canEdit}
        value={draft.value}
        onInput={(e) => {
          draft.value = (e.currentTarget as HTMLTextAreaElement).value;
          if (saving.current) clearTimeout(saving.current);
          saving.current = setTimeout(() => void save(), settle);
        }}
        onBlur={() => void save()} />
    </>
  );
}
