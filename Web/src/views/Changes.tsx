// What the agent changed, file by file (071 US4 scenario 2; the window's Changes pane): each file
// with its state and line counts, and opened, its diff as tinted lines. The diff is the host's
// (`changes/file`): git's hunks where the folder is a repository, else the agent's own edits.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { ChangedFile, ChangedFileDetail, ChangesList, DiffLine } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
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
        <Lines lines={[
          ...(edit.oldText ?? "").split("\n").filter((t, j, a) => j < a.length - 1 || t).map((text) => ({ kind: "removed" as const, text })),
          ...edit.newText.split("\n").filter((t, j, a) => j < a.length - 1 || t).map((text) => ({ kind: "added" as const, text })),
        ]} />
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
  useEffect(() => {
    void store.changes(host, session).then((l) => { list.value = l; failed.value = null; }, (e) => (failed.value = describe(e)));
  }, [host, session, changedAt, agentState]);
  useEffect(() => {
    detail.value = null;
    if (open) void store.changedFile(host, session, open).then((d) => (detail.value = d), (e) => (failed.value = describe(e)));
  }, [host, session, open, changedAt]);

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
