// What the agent changed, file by file (071 US4 scenario 2; the window's Changes pane): as a tree,
// folders first with their totals (#63), each file with a square in its status colour and its line
// counts, and opened, its diff: git's hunks where the folder is a
// repository, else the agent's own edits as line diffs (`changes/file`). Marked by sign, weight
// and a faint neutral wash; only a file's status square is coloured, as the window's is (#63).
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { ChangedFile, ChangedFileDetail, ChangesList, DiffLine } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { lineDiff, wantsWhole } from "../model/diff";
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

export function Lines({ lines }: { lines: DiffLine[] }) {
  return (
    <pre class="diff-lines">
      {lines.map((line, i) => (
        <span key={i} class={`diff-line ${line.kind}`}>
          <span class="sign" aria-hidden="true">{line.kind === "added" ? "+" : line.kind === "removed" ? "−" : " "}</span>
          {line.text}{"\n"}
        </span>
      ))}
    </pre>
  );
}

function Detail({ detail }: { detail: ChangedFileDetail }) {
  if (detail.hunks?.length) {
    return <>{detail.hunks.map((hunk, i) => (
      <div key={i} class="hunk">
        <p class="faint small">Line {hunk.newStart}</p>
        <Lines lines={hunk.lines} />
      </div>
    ))}</>;
  }
  if (detail.whole?.length) return <Lines lines={detail.whole} />;
  if (detail.edits.length) {
    // No repository: the agent's own edits, each as the text it replaced and the text it wrote.
    return <>{detail.edits.map((edit, i) => (
      <div key={i} class="hunk">
        <p class="faint small">{detail.edits.length > 1 ? `Edit ${i + 1}` : "Edit"}{edit.oldText === undefined ? " · made the file" : ""}</p>
        <Lines lines={lineDiff(edit.oldText, edit.newText)} />
      </div>
    ))}</>;
  }
  return <p class="hint">No lines to show for this file.</p>;
}

export function Changes({ store, host, session }: { store: Store; host: string; session: string }) {
  const list = useSignal<ChangesList | null>(null);
  const detail = useSignal<ChangedFileDetail | null>(null);
  const failed = useSignal<string | null>(null);
  const collapsed = useSignal<ReadonlySet<string>>(new Set());
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
  const whole = wantsWhole(list.value?.files.find((f) => f.path === open), list.value?.git);
  useEffect(() => {
    detail.value = null;
    let current = true;
    if (open) {
      void store.changedFile(host, session, open, whole).then(
        (d) => { if (current) detail.value = d; },
        (e) => { if (current) failed.value = describe(e); });
    }
    return () => { current = false; };
  }, [host, session, open, changedAt, whole]);

  if (failed.value && !list.value) return <p class="hint">{failed.value}</p>;
  if (!list.value) return <p class="hint">Reading what changed…</p>;
  if (!list.value.files.length) return <p class="hint">Nothing has changed yet.</p>;
  const shown = lines(build(list.value.files), collapsed.value);
  const toggle = (key: string) => {
    const next = new Set(collapsed.value);
    if (!next.delete(key)) next.add(key);
    collapsed.value = next;
  };
  const all = totals(shown.length ? build(list.value.files) : []);
  return (
    <div class="changes">
      {/* "4 files · +33 −0", as the window heads its list. */}
      <p class="changes-head quiet small">{all.files === 1 ? "1 file" : `${all.files} files`} · +{all.added} −{all.removed}</p>
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
            {open === node.file.path && (detail.value ? <Detail detail={detail.value} /> : <p class="hint">Reading the diff…</p>)}
          </li>
        ))}
      </ul>
      {/* The daemon names at most 500 files and counts the rest (#210), as the window says. */}
      {(list.value.more ?? 0) > 0 && (
        <p class="quiet small">{list.value.more === 1 ? "and 1 more file" : `and ${list.value.more} more files`}</p>
      )}
    </div>
  );
}
