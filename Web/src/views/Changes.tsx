// What the agent changed, file by file (071 US4 scenario 2; the window's Changes pane): each file
// with its state and line counts, and opened, its diff: git's hunks where the folder is a
// repository, else the agent's own edits as line diffs (`changes/file`). Marked by sign, weight
// and a faint neutral wash, never red and green: the app's one colour means something went wrong.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { ChangedFile, ChangedFileDetail, ChangesList, DiffLine } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { lineDiff, wantsWhole } from "../model/diff";
import { nameOf, paneOf, setPane } from "./files/paneState";

const stateWords: Record<ChangedFile["state"], string> = {
  modified: "Modified", added: "Added", deleted: "Deleted", binary: "Binary", renamed: "Renamed", untracked: "Untracked",
};

function Lines({ lines }: { lines: DiffLine[] }) {
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
  const open = paneOf(session).changed;
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
  return (
    <div class="changes">
      <ul class="changed-files" aria-label="Changed files">
        {list.value.files.map((file) => (
          <li key={file.path}>
            <button class={`row changed${open === file.path ? " chosen" : ""}`} aria-current={open === file.path}
              onClick={() => setPane(session, { changed: open === file.path ? undefined : file.path })}>
              <span class="title">{file.relativePath ?? nameOf(file.path)}</span>
              <span class="subtitle">
                {stateWords[file.state]}
                {file.added !== undefined && <span class="added"> +{file.added}</span>}
                {file.removed !== undefined && <span class="removed"> −{file.removed}</span>}
                {file.inProgress && " · being edited"}
              </span>
            </button>
            {open === file.path && (detail.value ? <Detail detail={detail.value} /> : <p class="hint">Reading the diff…</p>)}
          </li>
        ))}
      </ul>
    </div>
  );
}
