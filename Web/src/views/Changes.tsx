// What the agent changed, file by file (071 US4 scenario 2; the window's Changes pane): as a tree,
// folders first with their totals (#63), each file with a square in its status colour and its line
// counts, and opened, its diff. Edits or the whole file, as chosen, where both can be shown;
// Previous and Next through the whole file's changes; Open in Files (#259). Marked by sign, weight
// and a faint neutral wash; only a file's status square is coloured, as the window's is (#63).
// Changed words within a line stay unmarked, as #63 left them.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import type { ChangedFile, ChangedFileDetail, ChangesList, DiffLine, GitView } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { canOpenInFiles, changeStep, changeStops, lineDiff, offersDiffChoice, otherAgentsNote, shownDiff, unavailableNote, type DiffShown } from "../model/diff";
import { nameOf, paneOf, setPane } from "./files/paneState";
import { build, lines, sameFile, statusGlyph, statusPhrase, totals, type Totals } from "../model/changeTree";

/** A changed file's square, in its status colour, with the status in words for a reader (#63). */
export function StatusSquare({ file }: { file: ChangedFile }) {
  const words = statusPhrase(file);
  return <span class={`change-mark state-${file.state}`} role="img" aria-label={words} title={words[0]!.toUpperCase() + words.slice(1)}>{statusGlyph(file.state)}</span>;
}

/** "+3 −1", for a file or a folder's total. */
export function Counts({ added, removed }: { added?: number | undefined; removed?: number | undefined }) {
  if (!added && !removed) return null;
  return (
    <span class="counts">
      {added ? <span class="added">+{added}</span> : null}
      {removed ? <span class="removed"> −{removed}</span> : null}
    </span>
  );
}

const folderCounts = (t: Totals) => <Counts added={t.added} removed={t.removed} />;

export function Lines({ lines, scrollTo, scrollNonce }: { lines: DiffLine[]; scrollTo?: number | undefined; scrollNonce?: number | undefined }) {
  const pre = useRef<HTMLPreElement>(null);
  useLayoutEffect(() => {
    if (scrollTo === undefined) return;
    pre.current?.querySelector(`[data-row="${scrollTo}"]`)?.scrollIntoView({ block: "start" });
  }, [scrollTo, scrollNonce, lines]);
  return (
    <pre class="diff-lines" ref={pre}>
      {lines.map((line, i) => (
        <span key={i} class={`diff-line ${line.kind}`} data-row={i}>
          <span class="sign" aria-hidden="true">{line.kind === "added" ? "+" : line.kind === "removed" ? "−" : " "}</span>
          {line.text}{"\n"}
        </span>
      ))}
    </pre>
  );
}

function Detail({ detail, view, scrollTo, scrollNonce }: {
  detail: ChangedFileDetail; view: DiffShown; scrollTo?: number | undefined; scrollNonce?: number | undefined;
}) {
  if (view === "whole") {
    if (detail.whole) return <Lines lines={detail.whole} scrollTo={scrollTo} scrollNonce={scrollNonce} />;
    return <p class="hint">The whole file can't be shown.</p>;
  }
  if (detail.edits.length) {
    // The agent's own edits, each as the text it replaced and the text it wrote.
    return <>{detail.edits.map((edit, i) => (
      <div key={i} class="hunk">
        <p class="faint small">{detail.edits.length > 1 ? `Edit ${i + 1}` : "Edit"}{edit.oldText === undefined ? " · made the file" : ""}</p>
        <Lines lines={lineDiff(edit.oldText, edit.newText)} />
      </div>
    ))}</>;
  }
  if (detail.hunks?.length) {
    return <>{detail.hunks.map((hunk, i) => (
      <div key={i} class="hunk">
        <p class="faint small">Line {hunk.newStart}</p>
        <Lines lines={hunk.lines} />
      </div>
    ))}</>;
  }
  if (detail.file.inProgress) return <p class="hint">An edit to this file is still being made.</p>;
  return <p class="hint">No lines to show for this file.</p>;
}

/** Edits or Whole file, Previous and Next through the whole file, and Open in Files. */
function DiffBar({ file, git, view, stops, at, onView, onStep, onOpen }: {
  file: ChangedFile; git: GitView; view: DiffShown; stops: number[]; at: number | undefined;
  onView: (view: DiffShown) => void; onStep: (row: number) => void; onOpen: () => void;
}) {
  const choice = offersDiffChoice(file, git);
  const steps = view === "whole" && stops.length > 0;
  const open = canOpenInFiles(file);
  if (!choice && !steps && !open) return null;
  const previous = steps ? changeStep(stops, at, "previous") : undefined;
  const next = steps ? changeStep(stops, at, "next") : undefined;
  return (
    <div class="diff-bar">
      {choice && (
        <div class="diff-choice" role="group" aria-label="Diff view">
          <button type="button" aria-pressed={view === "edits"} onClick={() => onView("edits")}>Edits</button>
          <button type="button" aria-pressed={view === "whole"} onClick={() => onView("whole")}>Whole file</button>
        </div>
      )}
      {previous && next && (
        <div class="diff-steps">
          <button type="button" aria-label="Previous change" title="Previous change" disabled={!previous.enabled} onClick={() => onStep(previous.to)}>Previous</button>
          <button type="button" aria-label="Next change" title="Next change" disabled={!next.enabled} onClick={() => onStep(next.to)}>Next</button>
        </div>
      )}
      {open && <button type="button" class="link" onClick={onOpen}>Open in Files</button>}
    </div>
  );
}

export function Changes({ store, host, session }: { store: Store; host: string; session: string }) {
  const list = useSignal<ChangesList | null>(null);
  const detail = useSignal<ChangedFileDetail | null>(null);
  const failed = useSignal<string | null>(null);
  const collapsed = useSignal<ReadonlySet<string>>(new Set());
  // Whole file, when chosen for this path. A new file starts on the window's default.
  const choice = useSignal<{ path: string; view: DiffShown } | null>(null);
  // The change Previous or Next last went to, so the same one can be asked for again.
  const place = useSignal<{ path: string; stop?: number; nonce: number }>({ path: "", nonce: 0 });
  // The file open, by the path Changes lists it under: Show in Changes names it by the edit's path.
  const named = paneOf(session).changed;
  const open = named === undefined ? undefined : list.value?.files.find((f) => sameFile(f.path, named))?.path ?? named;
  // Read again whenever the agent's folders change.
  const changedAt = store.filesChanged.value?.agentID === session ? store.filesChanged.value.at : 0;
  const agentState = store.agent(host, session)?.state;
  // Each read is dropped if a later one has started: a slow answer for the last session or file
  // must not land under this one (the window's #89).
  useEffect(() => {
    let current = true;
    void store.changes(host, session).then(
      (l) => { if (current) { list.value = l; failed.value = null; } },
      (e) => { if (current) failed.value = describe(e); });
    return () => { current = false; };
  }, [host, session, changedAt, agentState]);
  // Opened from an edit in the chat, the file's row is brought into view.
  useEffect(() => {
    if (open) document.querySelector(".changes .row.changed.chosen")?.scrollIntoView({ block: "nearest" });
  }, [open, !!list.value]);
  const listed = open ? list.value?.files.find((f) => f.path === open) : undefined;
  const chosen = choice.value;
  const picked = chosen && chosen.path === open ? chosen.view : undefined;
  const view = shownDiff(picked, listed, list.value?.git);
  const askWhole = view === "whole";
  useEffect(() => {
    detail.value = null;
    let current = true;
    if (open) {
      void store.changedFile(host, session, open, askWhole).then(
        (d) => { if (current) detail.value = d; },
        (e) => { if (current) failed.value = describe(e); });
    }
    return () => { current = false; };
  }, [host, session, open, changedAt, askWhole]);
  // A newly opened file starts on the default, as the window's new selection does.
  useEffect(() => {
    if (choice.value && choice.value.path !== open) choice.value = null;
    if (place.value.path && place.value.path !== open) place.value = { path: "", nonce: 0 };
  }, [open]);

  if (failed.value && !list.value) return <p class="hint">{failed.value}</p>;
  if (!list.value) return <p class="hint">Reading what changed…</p>;
  const changes = list.value;
  // Why git's half is missing, as the Remote says it: a chat (#229) is in no repository.
  const unavailable = unavailableNote(changes.git);
  if (!changes.files.length) {
    return (
      <>
        <p class="hint">Nothing has changed yet.</p>
        {unavailable && <p class="changes-note faint small">{unavailable}</p>}
      </>
    );
  }
  const shown = lines(build(changes.files), collapsed.value);
  const toggle = (key: string) => {
    const next = new Set(collapsed.value);
    if (!next.delete(key)) next.add(key);
    collapsed.value = next;
  };
  const all = totals(shown.length ? build(changes.files) : []);
  const note = otherAgentsNote(changes.git);
  const here = place.value.path === open ? place.value : undefined;
  const stops = view === "whole" && detail.value?.whole ? changeStops(detail.value.whole) : [];
  return (
    <div class="changes">
      {/* "4 files · +33 −0", as the window heads its list. */}
      <p class="changes-head quiet small">{all.files === 1 ? "1 file" : `${all.files} files`} · +{all.added} −{all.removed}</p>
      {note && <p class="changes-note faint small">{note}</p>}
      {unavailable && <p class="changes-note faint small">{unavailable}</p>}
      <ul class="changed-files tree" aria-label="Changed files">
        {shown.map(({ node, depth }) => node.kind === "folder" ? (
          <li key={`folder:${node.key}`}>
            <button class="row tree-row folder" style={{ paddingLeft: `${8 + depth * 14}px` }} aria-expanded={!collapsed.value.has(node.key)}
              onClick={() => toggle(node.key)}>
              <span class="chevron" aria-hidden="true">{collapsed.value.has(node.key) ? "▸" : "▾"}</span>
              <span class="title">{node.name}</span>
              {folderCounts(node.totals)}
            </button>
          </li>
        ) : (
          <li key={node.file.path}>
            <button class={`row tree-row changed${open === node.file.path ? " chosen" : ""}`} style={{ paddingLeft: `${22 + depth * 14}px` }}
              aria-current={open === node.file.path}
              onClick={() => setPane(session, { changed: open === node.file.path ? undefined : node.file.path })}>
              <StatusSquare file={node.file} />
              <span class="title">{nameOf(node.file.path)}{node.file.inProgress && <span class="faint"> · being edited</span>}</span>
              <Counts added={node.file.added} removed={node.file.removed} />
            </button>
            {open === node.file.path && (
              <>
                <DiffBar file={detail.value?.file ?? node.file} git={changes.git} view={view} stops={stops} at={here?.stop}
                  onView={(next) => { choice.value = { path: node.file.path, view: next }; detail.value = null; }}
                  onStep={(row) => { place.value = { path: node.file.path, stop: row, nonce: place.value.nonce + 1 }; }}
                  onOpen={() => setPane(session, {
                    tab: "files", file: node.file.path,
                    fileLine: (detail.value?.file ?? node.file).firstLine, last: node.file.path,
                  })} />
                {detail.value
                  ? <Detail detail={detail.value} view={view} scrollTo={here?.stop} scrollNonce={here?.nonce} />
                  : <p class="hint">Reading the diff…</p>}
              </>
            )}
          </li>
        ))}
      </ul>
      {/* The daemon names at most 500 files and counts the rest (#210), as the window says. */}
      {(changes.more ?? 0) > 0 && (
        <p class="quiet small">{changes.more === 1 ? "and 1 more file" : `and ${changes.more} more files`}</p>
      )}
    </div>
  );
}
