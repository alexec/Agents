// A live page (071 US4 scenarios 3–4; LivePage.swift and PagePane.swift): a Markdown file the
// agent shows, drawn passage by passage, read again each time the host says its folder changed.
// What changed is typed in by the agent's caret, one passage after another, and the view follows
// the caret (#1236, the window's PageFollower; model/caret.ts). The person clicks a passage to type in it; what
// they type is merged with whatever the agent wrote meanwhile (PassageMerge) and written back
// through `artifact/write`, as the window writes it. While they type, the page doesn't move.
import { useSignal } from "@preact/signals";
import { useEffect, useMemo, useRef } from "preact/hooks";
import type { FileReading, FileStamp } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { idle, reveal, shown as shownOf, skip, tick, typingTick, type Caret } from "../model/caret";
import { pictureFromReading } from "../model/pageImage";
import { indexContaining, merge, split, type Passage } from "../model/passages";
import { Markdown, type PageImages } from "../render/markdown";
import { nameOf } from "./files/paneState";
import { usePageZoom } from "./files/pageZoomKeys";

type Loaded =
  | { kind: "reading" }
  | { kind: "notYet" }
  | { kind: "text"; text: string; stamp: FileStamp; truncated: boolean }
  | { kind: "gone"; last: string }
  | { kind: "refused"; why: string };

/** How long typing rests before it is written. */
const settle = 700;
/** How long the passage holding a line the agent named stays marked. */
const markFor = 2_500;

interface Editing {
  /** The document when the edit began: what `mine` is a passage of. */
  base: string;
  mine: Passage;
  index: number;
  draft: string;
}

/**
 * Where a page is read and written: an agent's folder (the default), or a folder's own folder
 * for a pinned page (#159). `changed` moves whenever the page may have changed on disk.
 */
export interface PageSource {
  read: (stamp?: FileStamp) => Promise<FileReading>;
  write: (text: string) => Promise<boolean>;
  watch: () => () => void;
  changed: number | undefined;
}

export function LiveDocument({ store, host, agentID, path, line, source }: {
  store: Store; host: string; agentID: string; path: string; line?: number | undefined; source?: PageSource | undefined;
}) {
  const loaded = useSignal<Loaded>({ kind: "reading" });
  const editing = useSignal<Editing | null>(null);
  const theirs = useSignal<string | null>(null);
  const marked = useSignal<Set<number>>(new Set());
  const caret = useSignal<Caret>(idle);
  // How large the page's text is drawn, and ⌘+, ⌘− and ⌘0 while it is shown (#1419).
  const zoom = usePageZoom();
  const typist = useRef<ReturnType<typeof setInterval> | null>(null);
  const saving = useRef<ReturnType<typeof setTimeout> | null>(null);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const later = (run: () => void, ms: number) => {
    const timer = setTimeout(() => {
      timers.current = timers.current.filter((t) => t !== timer);
      run();
    }, ms);
    timers.current.push(timer);
  };
  useEffect(() => () => {
    for (const timer of timers.current) clearTimeout(timer);
    timers.current = [];
    if (saving.current) clearTimeout(saving.current);
    if (typist.current) clearInterval(typist.current);
  }, []);
  const container = useRef<HTMLDivElement>(null);
  const folder = path.slice(0, path.lastIndexOf("/")) || "/";
  const name = nameOf(path);
  const change = store.filesChanged.value;
  const page: PageSource = source ?? {
    read: (stamp) => store.readFile(host, agentID, path, stamp),
    write: (text) => store.writeArtifact(host, agentID, path, text),
    watch: () => {
      store.watchFolder(host, agentID, folder);
      return () => store.unwatchFolder(host, agentID, folder);
    },
    changed: change && change.agentID === agentID
      && (change.many || change.folders.some((f) => f.replace(/\/+$/, "") === folder))
      ? change.at : undefined,
  };

  // Reads are counted, and any that lands after a later one started is dropped (the window's #89).
  const reads = useRef(0);
  const read = async () => {
    const was = loaded.peek();
    const n = ++reads.current;
    try {
      const r = await page.read(was.kind === "text" ? was.stamp : undefined);
      if (n !== reads.current || r.kind === "unchanged") return;
      if (r.kind !== "text") {
        loaded.value = { kind: "refused", why: `${name} is not text, so it can't be read as a page.` };
        return;
      }
      const before = was.kind === "text" ? split(was.text) : [];
      loaded.value = { kind: "text", text: r.text, stamp: r.stamp, truncated: r.isTruncated };
      // What changed is queued for the caret, which takes the view to each passage as it reaches
      // it. A write is not marked as well: the caret typing it in says where it changed, as on the
      // window. Only a change with nothing to type, a deletion, moves the view by hand.
      const after = split(r.text);
      const changed = after.map((p, i) => (before[i]?.source === p.source ? -1 : i)).filter((i) => i >= 0);
      if (after.length < before.length) changed.push(after.length);
      if (changed.length && was.kind === "text") {
        const typing = editing.peek()?.index;
        const queued = reveal(before.map((p) => p.source), after.map((p) => p.source), changed.filter((i) => i !== typing));
        caret.value = queued;
        if (queued.revealing) startTyping();
        else if (typing === undefined) go(Math.min(changed[0]!, Math.max(0, after.length - 1)));
      }
    } catch (error) {
      if (n !== reads.current) return;
      const message = describe(error);
      if (/is gone/.test(message)) {
        loaded.value = was.kind === "text" ? { kind: "gone", last: was.text } : was.kind === "gone" ? was : { kind: "notYet" };
      } else if (was.kind === "reading") {
        loaded.value = { kind: "refused", why: message };
      }
    }
  };

  // The caret's beat: typingStep characters every typingTick, until nothing is left to type.
  const startTyping = () => {
    if (typist.current) return;
    typist.current = setInterval(() => {
      const now = loaded.peek();
      const sources = now.kind === "text" ? split(now.text).map((p) => p.source) : [];
      caret.value = tick(caret.peek(), sources);
      if (!caret.peek().revealing && typist.current) { clearInterval(typist.current); typist.current = null; }
    }, typingTick);
  };

  // The view follows the caret from passage to passage, and stays put while the person types.
  const typingAt = caret.value.revealing?.index;
  useEffect(() => {
    if (typingAt !== undefined && !editing.peek()) go(typingAt);
  }, [typingAt]);

  const go = (index: number) => {
    requestAnimationFrame(() => container.current?.querySelector(`[data-passage="${index}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" }));
  };

  useEffect(() => {
    loaded.value = { kind: "reading" };
    editing.value = null;
    caret.value = idle;
    const unwatch = page.watch();
    void read();
    return unwatch;
  }, [host, agentID, path]);

  // Shown again (the agent asking for it, or Show plan): read again. A plan is shown as it starts
  // being written, so the first read can come before there is anything, in a folder no watch covers.
  const shown = store.shownFile.value;
  useEffect(() => {
    if (shown && shown.host === host && shown.agentID === agentID && shown.path === path) void read();
  }, [shown?.at]);

  // The host says the folder changed: read again, with the stamp held so an unchanged file costs nothing.
  useEffect(() => {
    if (page.changed !== undefined) void read();
  }, [page.changed]);

  // The line the agent named: go to its passage, once the page has it.
  useEffect(() => {
    const now = loaded.value;
    if (line && now.kind === "text") {
      const index = indexContaining(line, split(now.text));
      if (index !== null) {
        go(index);
        marked.value = new Set([index]);
        later(() => (marked.value = new Set()), markFor);
      }
    }
  }, [line, loaded.value.kind]);

  const save = async () => {
    const edit = editing.peek();
    const now = loaded.peek();
    if (!edit || now.kind !== "text") return;
    const result = merge(edit.base, now.text, edit.mine, edit.draft);
    const outcome = "merged" in result ? result.merged : result.collided;
    theirs.value = "collided" in result && result.collided.theirs ? result.collided.theirs : null;
    if (!(await page.write(outcome.text))) return;
    // What was written is now the base: the next keystroke merges against it.
    const passages = split(outcome.text);
    const mine = passages[outcome.passageIndex];
    if (mine && editing.peek()) editing.value = { ...editing.peek()!, base: outcome.text, mine, index: outcome.passageIndex };
    loaded.value = { ...now, text: outcome.text };
  };

  const type = (draft: string) => {
    if (!editing.peek()) return;
    editing.value = { ...editing.peek()!, draft };
    if (saving.current) clearTimeout(saving.current);
    saving.current = setTimeout(() => void save(), settle);
  };

  const finish = () => {
    if (saving.current) { clearTimeout(saving.current); saving.current = null; void save().then(() => (editing.value = null)); }
    else editing.value = null;
  };

  // Opened while the caret is in it, or waiting for it: the person gets it whole at once.
  const open = (passage: Passage, index: number) => {
    caret.value = skip(caret.peek(), index);
    editing.value = { base: text, mine: passage, index, draft: passage.source };
  };

  const focusOnce = (el: HTMLTextAreaElement | null) => {
    if (el && document.activeElement !== el) el.focus();
  };

  // Pictures beside this page, read again when its folder changes. A remote one stays a placeholder.
  const images: PageImages = useMemo(() => ({
    document: path,
    revision: page.changed ?? 0,
    read: (file) => store.readFile(host, agentID, file).then((r) => pictureFromReading(file, r), () => null),
  }), [path, page.changed, host, agentID, store]);
  const state = loaded.value;
  const text = state.kind === "text" ? state.text : state.kind === "gone" ? state.last : "";
  const passages = split(text);
  const canEdit = state.kind === "text" && store.link.state.kind === "open" && store.hostIsOnline(host);
  return (
    <div class="live-page" ref={container}>
      {state.kind === "notYet" && <p class="quiet small">Not written yet. {name} will appear here as it is.</p>}
      {state.kind === "gone" && <p class="quiet small">{name} is gone. This is what it last said.</p>}
      {state.kind === "text" && state.truncated && <p class="quiet small">Only the start of {name} is shown.</p>}
      {state.kind === "refused" && <p class="hint">{state.why}</p>}
      {state.kind === "reading" && <p class="hint">Reading {name}…</p>}
      {theirs.value && (
        <div class="note switch" role="status">
          <p class="strong">The agent changed this passage while you were typing. What it wrote:</p>
          <div class="quiet"><Markdown text={theirs.value} images={images} /></div>
          <button class="link" onClick={() => (theirs.value = null)}>OK</button>
        </div>
      )}
      <article class={`page${state.kind === "gone" ? " gone" : ""}`} aria-label={name} style={zoom}>
        {passages.map((passage, index) => {
          const edit = editing.value;
          if (edit && edit.index === index) {
            return (
              <textarea key={`edit-${index}`} data-passage={index} class="passage-editor" aria-label={`Editing ${name}`}
                value={edit.draft} rows={Math.max(2, edit.draft.split("\n").length + 1)}
                ref={focusOnce}
                onInput={(e) => type((e.currentTarget as HTMLTextAreaElement).value)}
                onBlur={finish}
                onKeyDown={(e) => { if (e.key === "Escape") { e.preventDefault(); finish(); } }} />
            );
          }
          return (
            <div key={index} data-passage={index} class={`passage${marked.value.has(index) ? " marked" : ""}${passage.isHeading ? " heading" : ""}${typingAt === index ? " typing" : ""}`}
              aria-busy={typingAt === index ? true : undefined}
              role={canEdit ? "button" : undefined} tabIndex={canEdit ? 0 : undefined}
              title={canEdit ? "Click to edit this passage" : undefined}
              onClick={() => {
                if (!canEdit || editing.peek()) return;
                open(passage, index);
              }}
              onKeyDown={(e) => {
                if (canEdit && e.key === "Enter" && !editing.peek()) {
                  e.preventDefault();
                  open(passage, index);
                }
              }}>
              <Markdown text={shownOf(caret.value, index, passage.source)} images={images} />
            </div>
          );
        })}
        {passages.length === 0 && canEdit && !editing.value && (
          <div class="passage empty" role="button" tabIndex={0} onClick={() => (editing.value = {
            base: text, mine: { source: "", lines: [1, 1], separator: "\n", isHeading: false }, index: 0, draft: "" })}>
            <p class="faint">Click to start writing.</p>
          </div>
        )}
        {passages.length === 0 && editing.value && (
          <textarea data-passage={0} class="passage-editor" aria-label={`Editing ${name}`} value={editing.value.draft} rows={4}
            ref={focusOnce}
            onInput={(e) => type((e.currentTarget as HTMLTextAreaElement).value)} onBlur={finish} />
        )}
      </article>
    </div>
  );
}
