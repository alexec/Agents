// A file that is not a page, open for typing (#415), as the window's SourceEditor: its source in
// the code face, saved through artifact/write a moment after the typing stops and when the field
// is left. While nothing typed is waiting to be saved, a change on disk is taken in place; while
// something is, the person's text wins and is written over it.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import type { Store } from "../../model/store";
import type { FileCompletion, FileDiagnostic, FileDiagnostics } from "../../protocol/generated";
import { nameOf } from "./paneState";
import { describe } from "../../model/errors";
import { Capability } from "../../protocol/capabilities.generated";
import { hostNeedsUpdate } from "../../model/capabilities";

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
  /** What the file's language server found, as last asked (#844). */
  const problems = useSignal<FileDiagnostics | null>(null);

  // The language server is asked a moment after the typing stops (#844).
  const typed = draft.value;
  useEffect(() => {
    // Not asked of a host too old to have a language server here (#1748); said in the
    // problems' place, not "no problems" (#1866).
    if (!store.has(host, Capability.filesDiagnostics1)) {
      problems.value = { diagnostics: [], reason: hostNeedsUpdate };
      return;
    }
    let gone = false;
    const timer = setTimeout(() => {
      void store.link.call("files/diagnostics", { agentID: agentID as never, path, text: typed }, host)
        .then((found) => { if (!gone) problems.value = found; }, (error: unknown) => {
          // A failed request says so, not "no problems" (#1687).
          if (gone) return;
          const server = problems.peek()?.server ?? "the language server";
          problems.value = { diagnostics: [], server, reason: `Couldn't ask ${server}: ${describe(error)}` };
        });
    }, 1000);
    return () => { gone = true; clearTimeout(timer); };
  }, [typed, path, host]);

  /** The language server's words for the caret's place (#844), while the list is up. */
  const offered = useSignal<FileCompletion[] | null>(null);
  const chosen = useSignal(0);
  /** Why an asked completion brought nothing, shown for a moment (#1688). */
  const note = useSignal<string | null>(null);
  const noteTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const say = (words: string) => {
    note.value = words;
    if (noteTimer.current) clearTimeout(noteTimer.current);
    noteTimer.current = setTimeout(() => { note.value = null; }, 4000);
  };
  const ask = async () => {
    const el = field.current;
    if (!el) return;
    if (!store.has(host, Capability.filesComplete1)) { say(hostNeedsUpdate); return; }
    const before = el.value.slice(0, el.selectionStart);
    const line = before.split("\n").length;
    const column = before.length - (before.lastIndexOf("\n") + 1) + 1;
    const found = await store.link.call("files/complete", { agentID: agentID as never, path, text: el.value, line, column }, host)
      .catch((error: unknown) => ({ items: [], reason: `Couldn't ask for completions: ${describe(error)}` }));
    // As the Mac's list: those that start with the word being typed, or all when none do.
    const typedWord = (/[A-Za-z0-9_]*$/.exec(before)?.[0] ?? "").toLowerCase();
    const items = found.items;
    const matching = items.filter((item) => (item.insert ?? item.label).toLowerCase().startsWith(typedWord));
    const shown = matching.length ? matching : items;
    offered.value = shown.length ? shown : null;
    chosen.value = 0;
    if (!shown.length) say(found.reason ?? "No completions here.");
  };
  /** The word being typed, before the caret, goes; the chosen one takes its place. */
  const take = (item: FileCompletion) => {
    const el = field.current;
    offered.value = null;
    if (!el) return;
    const at = el.selectionStart;
    const start = at - (/[A-Za-z0-9_]*$/.exec(el.value.slice(0, at))?.[0].length ?? 0);
    el.setRangeText(item.insert ?? item.label, start, at, "end");
    draft.value = el.value;
    if (saving.current) clearTimeout(saving.current);
    saving.current = setTimeout(() => void save(), settle);
    el.focus();
  };

  const goTo = (target: number) => {
    const el = field.current;
    if (!el) return;
    const at = offsetOfLine(el.value, target);
    el.focus();
    el.setSelectionRange(at, at);
    const lineHeight = parseFloat(getComputedStyle(el).lineHeight) || 18;
    el.scrollTop = Math.max(0, (target - 1) * lineHeight - el.clientHeight / 2);
  };

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
        onKeyDown={(e) => {
          // Ctrl+Space asks the language server what to write here (#844); the list takes the arrows.
          // Alt+Esc too, the Mac's own key, as a Mac takes Ctrl+Space for the input source (#1688).
          if ((e.key === " " && e.ctrlKey) || (e.key === "Escape" && e.altKey)) { e.preventDefault(); void ask(); return; }
          const list = offered.value;
          if (!list) return;
          if (e.key === "Escape") { e.preventDefault(); offered.value = null; }
          else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
            e.preventDefault();
            chosen.value = Math.max(0, Math.min(list.length - 1, chosen.value + (e.key === "ArrowDown" ? 1 : -1)));
          } else if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); take(list[chosen.value]!); }
        }}
        onBlur={() => void save()} />
      {offered.value && (
        <div class="source-completions" role="listbox" aria-label="Completions">
          {offered.value.map((item, i) => (
            <button key={i} type="button" role="option" aria-selected={i === chosen.value} class={`completion${i === chosen.value ? " chosen" : ""}`}
              onMouseDown={(e) => { e.preventDefault(); take(item); }}>
              <span>{item.label}</span>{item.detail && <span class="faint small"> {item.detail}</span>}
            </button>
          ))}
        </div>
      )}
      {note.value && <p class="faint small completion-note" role="status">{note.value}</p>}
      {problems.value?.server && canEdit && !note.value && <p class="faint small completion-note">Ctrl+Space or Alt+Esc: complete</p>}
      {problems.value && <Problems found={problems.value} goTo={goTo} />}
    </>
  );
}

/**
 * What a file's language server found (ProblemsList, #844), under the editor: each problem's place
 * and words, a click away from its line. Nothing when the file's language has no server; why when
 * it is not installed, is starting or did not answer; "No problems · ‹server›" once it answered
 * with none (#1687).
 */
function Problems({ found, goTo }: { found: FileDiagnostics; goTo: (line: number) => void }) {
  if (!found.server) return null;
  const heading = problemsHeading(found);
  const mark = (p: FileDiagnostic) => (p.severity === "error" ? "⛔" : p.severity === "warning" ? "⚠️" : "ℹ️");
  return (
    <div class="problems" role="group" aria-label="Problems">
      <p class="faint small">{heading}</p>
      {found.diagnostics.map((p, i) => (
        <button key={i} type="button" class="source-problem" title={`Go to line ${p.line}`} onClick={() => goTo(p.line)}>
          <span aria-label={p.severity}>{mark(p)}</span> <span class="faint">{p.line}:{p.column}</span> {p.message}
        </button>
      ))}
    </div>
  );
}

/** The problems list's first line (#1687): why, "No problems · ‹server›", or how many. */
export function problemsHeading(found: FileDiagnostics): string {
  const count = found.diagnostics.length;
  if (found.reason && count === 0) return found.reason;
  if (count === 0) return `No problems · ${found.server ?? ""}`;
  return `${count} ${count === 1 ? "problem" : "problems"} · ${found.server ?? ""}`;
}
