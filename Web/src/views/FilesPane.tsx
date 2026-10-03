// The files pane (071 US4; frame B): a fourth column from 1440, over the chat below that. Three
// tabs, as the window's pane has: Files (the session's folder, browsed, a file opened), Changes
// (what the agent changed), and Page (a live page the agent shows, or one opened from Files).
import { signal, useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { DirectoryEntry } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { replace, route } from "../route";
import { Changes, Counts, StatusSquare } from "./Changes";
import { canonical, index } from "../model/changeTree";
import type { ChangesList } from "../protocol/generated";
import { FileView } from "./files/FileView";
import { Tree } from "./files/Tree";
import { sorted } from "../model/fileTree";
import { extensionOf, nameOf, paneOf, pathOf, setPane, type Tab } from "./files/paneState";
import { LiveDocument } from "./LiveDocument";

const tabs: { tab: Tab; label: string }[] = [
  { tab: "files", label: "Files" }, { tab: "changes", label: "Changes" }, { tab: "page", label: "Page" },
];

/** Below 760 the page is the phone's one column at a time, and Files lists one folder at a time, as the Remote does. */
const narrowQuery = typeof matchMedia === "function" ? matchMedia("(max-width: 759px)") : null;
const narrow = signal(narrowQuery?.matches ?? false);
narrowQuery?.addEventListener("change", (e) => { narrow.value = e.matches; });

/** A file open under Files, with Back to where it was opened from. */
function OpenFile({ store, host, session, file, back }: { store: Store; host: string; session: string; file: string; back: string }) {
  return (
    <div class="file">
      <div class="crumbs">
        {/* Back finds the folder with this file marked (#66). */}
        <button class="link" onClick={() => setPane(session, { file: undefined, last: file })}>‹ {nameOf(back)}</button>
        <span class="title">{nameOf(file)}</span>
        {(extensionOf(file) === "md" || extensionOf(file) === "markdown") && (
          <button class="link" onClick={() => setPane(session, { tab: "page", page: file, line: undefined })}>Open as Page</button>
        )}
      </div>
      <FileView store={store} host={host} agentID={session} path={file} />
    </div>
  );
}

function Browser({ store, host, session, root }: { store: Store; host: string; session: string; root: string }) {
  const pane = paneOf(session);
  const changedAt = store.filesChanged.value?.agentID === session ? store.filesChanged.value.at : 0;
  // What changed, for the same rows as Changes: a changed file in its status colour, a folder
  // with the total under it (#63). Asked while the pane is shown, again on each change.
  const changes = useSignal<ChangesList | null>(null);
  useEffect(() => {
    let current = true;
    void store.changes(host, session).then((l) => { if (current) changes.value = l; }, () => {});
    return () => { current = false; };
  }, [host, session, changedAt]);
  const marks = index(changes.value?.files ?? []);
  if (narrow.value) return <FolderList store={store} host={host} session={session} root={root} marks={marks} changedAt={changedAt} />;
  // The tree stays under an open file rather than going, so Back finds it as it was left (#66).
  return (
    <>
      {pane.file && <OpenFile store={store} host={host} session={session} file={pane.file} back={root} />}
      {!pane.file && <div class="crumbs"><span class="title">{nameOf(root)}</span></div>}
      <Tree store={store} host={host} session={session} root={root} marks={marks} changedAt={changedAt} hidden={!!pane.file} />
    </>
  );
}

/** The phone's way: one folder at a time, a folder tapped to go into it, Back to come out. */
function FolderList({ store, host, session, root, marks, changedAt }: {
  store: Store; host: string; session: string; root: string; marks: ReturnType<typeof index>; changedAt: number;
}) {
  const pane = paneOf(session);
  const folder = pane.folder ?? root;
  const entries = useSignal<DirectoryEntry[]>([]);
  const failed = useSignal<string | null>(null);
  useEffect(() => {
    failed.value = null;
    // A slow listing of the last folder must not land under this one (the window's #89).
    let current = true;
    void store.listFiles(host, session, folder).then(
      (listing) => { if (current) entries.value = sorted(listing).entries; },
      (e) => { if (current) { entries.value = []; failed.value = describe(e); } });
    return () => { current = false; };
  }, [host, session, folder, changedAt]);
  useEffect(() => {
    store.watchFolder(host, session, folder);
    return () => store.unwatchFolder(host, session, folder);
  }, [host, session, folder]);

  if (pane.file) return <OpenFile store={store} host={host} session={session} file={pane.file} back={folder} />;
  // Up to the session's own folder and no further: the host refuses anything outside it.
  const parent = folder !== root && folder.startsWith(root) ? folder.slice(0, folder.lastIndexOf("/")) || "/" : null;
  return (
    <div class="browser">
      <div class="crumbs">
        {parent && <button class="link" onClick={() => setPane(session, { folder: parent === root ? undefined : parent })}>‹ {nameOf(parent)}</button>}
        <span class="title">{nameOf(folder)}</span>
      </div>
      {failed.value && <p class="hint">{failed.value}</p>}
      <ul class="entries" aria-label={`Files in ${nameOf(folder)}`}>
        {entries.value.map((entry) => {
          const path = pathOf(entry.url);
          const changed = entry.isDirectory ? undefined : marks.files.get(canonical(path));
          const total = entry.isDirectory ? marks.folders.get(canonical(path)) : undefined;
          const last = pane.last === path;
          return (
            <li key={entry.url}>
              <button class={`row entry${last ? " chosen" : ""}`} aria-current={last}
                onClick={() => setPane(session, entry.isDirectory ? { folder: path } : { file: path, last: path })}>
                <span class="title">
                  {changed ? <StatusSquare file={changed} /> : <span aria-hidden="true">{entry.isDirectory ? "📁" : "📄"}</span>} {entry.name}
                </span>
                {changed ? <Counts added={changed.added} removed={changed.removed} /> : total ? <Counts added={total.added} removed={total.removed} /> : null}
              </button>
            </li>
          );
        })}
        {!failed.value && entries.value.length === 0 && <li class="hint">Nothing here.</li>}
      </ul>
    </div>
  );
}

export function FilesPane({ store, host, session }: { store: Store; host: string; session: string }) {
  const agent = store.agent(host, session);
  const pane = paneOf(session);
  const root = agent ? pathOf(agent.cwd) : null;
  return (
    <aside class="files" aria-label="Files">
      <header class="column-head">
        <span class="tabs" role="tablist">
          {tabs.map(({ tab, label }) => (
            <button key={tab} role="tab" class={`tab${pane.tab === tab ? " chosen" : ""}`} aria-selected={pane.tab === tab}
              onClick={() => setPane(session, { tab })}>{label}</button>
          ))}
        </span>
        <button class="icon" aria-label="Close Files" onClick={() => replace({ ...route.value, files: false })}>✕</button>
      </header>
      <div class="scroll pane-body">
        {pane.tab === "files" && root && <Browser key={session} store={store} host={host} session={session} root={root} />}
        {pane.tab === "changes" && <Changes store={store} host={host} session={session} />}
        {pane.tab === "page" && (pane.page
          ? <LiveDocument store={store} host={host} agentID={session} path={pane.page} line={pane.line} />
          : <p class="hint">A Markdown file the agent shows, or one you open from Files, reads here.</p>)}
      </div>
    </aside>
  );
}
