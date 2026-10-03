// Files as a tree, at desktop widths (#133; the window's FilesPane listing): folders open and shut
// in place, read only when opened; the open folders kept in the pane's state, so opening a file
// and going Back finds the tree as it was, the file marked (#66); the same change marks as Changes
// (#63); the keys of a tree; and only the rows in view drawn, so a big folder stays quick.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import type { ChangedFile, DirectoryListing } from "../../protocol/generated";
import type { Store } from "../../model/store";
import { describe } from "../../model/errors";
import { canonical, fileWords, totalWords, type Totals } from "../../model/changeTree";
import { flatten, keyAction, reveal, sorted, unread, visibleFolders, windowOf, type TreeLine } from "../../model/fileTree";
import { Counts, StatusSquare } from "../Changes";
import { nameOf, paneOf, setPane } from "./paneState";

/** Every row is this tall, so the rows in view can be worked out from the scroll alone. */
const rowHeight = 26;
const indent = (depth: number) => 8 + depth * 14;
const parentOf = (path: string) => path.slice(0, path.lastIndexOf("/")) || "/";
/** A row's element id, for aria-activedescendant. */
const rowID = (session: string, id: string) => `tree-${session}-${encodeURIComponent(id)}`;
const none: ReadonlySet<string> = new Set();

interface Marks { files: Map<string, ChangedFile>; folders: Map<string, Totals> }

export function Tree({ store, host, session, root, marks, changedAt, hidden }: {
  store: Store; host: string; session: string; root: string; marks: Marks; changedAt: number; hidden: boolean;
}) {
  const pane = paneOf(session);
  const expanded = pane.expanded ?? none;
  const listings = useSignal<ReadonlyMap<string, DirectoryListing>>(new Map());
  const problems = useSignal<ReadonlyMap<string, string>>(new Map());
  // Folders with a read on its way, and the number of the latest read of each: a slower earlier
  // read landing after a later one is dropped (the window's #89).
  const reading = useRef(new Set<string>());
  const requests = useRef(new Map<string, number>());
  const alive = useRef(true);
  const list = useRef<HTMLUListElement>(null);
  const scroll = useSignal({ top: 0, height: 600 });

  const read = (folder: string) => {
    const request = (requests.current.get(folder) ?? 0) + 1;
    requests.current.set(folder, request);
    reading.current.add(folder);
    const settle = (change: () => void) => {
      if (!alive.current || requests.current.get(folder) !== request) return;
      reading.current.delete(folder);
      change();
    };
    void store.listFiles(host, session, folder).then(
      (listing) => settle(() => {
        listings.value = new Map(listings.value).set(folder, sorted(listing));
        if (problems.value.has(folder)) { const next = new Map(problems.value); next.delete(folder); problems.value = next; }
      }),
      (e) => settle(() => {
        const next = new Map(listings.value); next.delete(folder); listings.value = next;
        problems.value = new Map(problems.value).set(folder, describe(e));
      }));
  };

  useEffect(() => {
    alive.current = true;
    store.watchFolder(host, session, root);
    return () => { alive.current = false; store.unwatchFolder(host, session, root); };
  }, [host, session, root]);

  // A file opened, here or from elsewhere: its folders opened down to it, so Back has it in view.
  useEffect(() => {
    const file = pane.file ?? pane.last;
    if (!file) return;
    const opened = reveal(root, parentOf(file), expanded);
    if (opened.size !== expanded.size) setPane(session, { expanded: opened });
  }, [pane.file, root]);

  // Open folders on screen that have not been read: the top, one revealed, or the pane drawn
  // afresh with folders still open.
  useEffect(() => {
    for (const folder of unread(root, expanded, listings.value, problems.value, reading.current)) read(folder);
  }, [root, expanded, listings.value, problems.value]);

  // The disk changed: every folder on screen read again, the old rows kept until the new are in.
  const lastChange = useRef(changedAt);
  useEffect(() => {
    if (changedAt === lastChange.current) return;
    lastChange.current = changedAt;
    for (const folder of visibleFolders(root, expanded, listings.value)) read(folder);
  }, [changedAt]);

  // Which rows are in view: the pane's own scroll, measured from where the list starts in it.
  const scroller = () => list.current?.closest<HTMLElement>(".scroll") ?? null;
  const offset = () => {
    const s = scroller(), l = list.current;
    return s && l ? l.getBoundingClientRect().top - s.getBoundingClientRect().top + s.scrollTop : 0;
  };
  useEffect(() => {
    const s = scroller();
    if (!s) return;
    const measure = () => { scroll.value = { top: s.scrollTop - offset(), height: s.clientHeight }; };
    measure();
    s.addEventListener("scroll", measure, { passive: true });
    const resized = new ResizeObserver(measure);
    resized.observe(s);
    return () => { s.removeEventListener("scroll", measure); resized.disconnect(); };
  }, [hidden]);

  const lines = flatten(root, listings.value, expanded, problems.value);
  const at = (id: string | undefined) => (id === undefined ? -1 : lines.findIndex((l) => l.id === id));

  /** Bring a row into the pane's view: just enough, or centred, as Back does (#66). */
  const bringIntoView = (index: number, centre: boolean) => {
    const s = scroller();
    if (!s || index < 0) return;
    const top = offset() + index * rowHeight;
    if (centre) s.scrollTop = top - (s.clientHeight - rowHeight) / 2;
    else if (top < s.scrollTop) s.scrollTop = top;
    else if (top + rowHeight > s.scrollTop + s.clientHeight) s.scrollTop = top + rowHeight - s.clientHeight;
  };
  // Back from a file, or the tree drawn afresh: the file last open centred once its row is read.
  const centred = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    if (hidden) { centred.current = undefined; return; }
    if (!pane.last || centred.current === pane.last) return;
    const index = at(pane.last);
    if (index < 0) return;
    centred.current = pane.last;
    bringIntoView(index, true);
  });

  const toggle = (path: string) => {
    const next = new Set(expanded);
    if (!next.delete(path)) {
      next.add(path);
      // Opening reads it again even when it was read before: what it held then may not be now.
      read(path);
    }
    setPane(session, { expanded: next, cursor: path });
  };
  const open = (line: TreeLine & { kind: "entry" }) => {
    if (line.entry.isDirectory) toggle(line.path);
    else setPane(session, { file: line.path, fileLine: undefined, last: line.path, cursor: line.path });
  };
  const cursor = pane.cursor ?? pane.last;
  const onKey = (e: KeyboardEvent) => {
    const action = keyAction(lines, cursor, e.key, expanded, root);
    if (action.kind === "none") return;
    e.preventDefault();
    if (action.kind === "select") { setPane(session, { cursor: action.id }); bringIntoView(at(action.id), false); }
    else if (action.kind === "expand" || action.kind === "collapse") toggle(action.path);
    else open(action.line);
  };

  const { start, end } = windowOf(lines.length, rowHeight, scroll.value.top, scroll.value.height);
  return (
    <ul ref={list} class="tree file-tree" role="tree" aria-label={`Files in ${nameOf(root)}`} tabIndex={0}
      aria-activedescendant={at(cursor) >= 0 ? rowID(session, cursor!) : undefined}
      style={{ height: `${lines.length * rowHeight}px`, display: hidden ? "none" : undefined }} onKeyDown={onKey}>
      {lines.slice(start, end).map((line, i) => {
        const top = { top: `${(start + i) * rowHeight}px`, height: `${rowHeight}px`, paddingLeft: `${indent(line.depth)}px` };
        if (line.kind === "note") return <li key={line.id} class="tree-row note faint small" role="none" style={top}>{line.words}</li>;
        if (line.kind === "problem") {
          return (
            <li key={line.id} class="tree-row note small" role="none" style={top}>
              <span class="quiet">{line.words}</span> <button class="link" onClick={() => read(line.folder)}>Try Again</button>
            </li>
          );
        }
        const { entry, path } = line;
        const isOpen = entry.isDirectory && expanded.has(path);
        const changed = entry.isDirectory ? undefined : marks.files.get(canonical(path));
        const total = entry.isDirectory ? marks.folders.get(canonical(path)) : undefined;
        const marked = pane.last === path;
        // One element a row, named in words (#71): what is drawn inside is hidden from a reader.
        const words = changed ? fileWords(changed, entry.name)
          : entry.isDirectory ? (total ? `${entry.name}, folder, ${totalWords(total)}` : `${entry.name}, folder`) : entry.name;
        return (
          <li key={line.id} id={rowID(session, line.id)} role="treeitem" aria-level={line.depth + 1} aria-label={words}
            aria-expanded={entry.isDirectory ? isOpen : undefined} aria-selected={marked}
            class={`row tree-row entry${marked ? " chosen" : ""}${cursor === path ? " cursor" : ""}`} style={top}
            onClick={() => open(line)}>
            <span class="chevron" aria-hidden="true">{entry.isDirectory ? (isOpen ? "▾" : "▸") : ""}</span>
            <span class="title" aria-hidden="true">
              {changed ? <StatusSquare file={changed} /> : <span class="icon">{entry.isDirectory ? "📁" : "📄"}</span>} {entry.name}
            </span>
            <span aria-hidden="true">{changed ? <Counts added={changed.added} removed={changed.removed} />
              : total ? <Counts added={total.added} removed={total.removed} /> : null}</span>
          </li>
        );
      })}
    </ul>
  );
}
