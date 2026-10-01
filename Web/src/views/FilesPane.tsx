// The files pane (071 US4; frame B): a fourth column from 1440, over the chat below that. Three
// tabs, as the window's pane has: Files (the session's folder, browsed, a file opened), Changes
// (what the agent changed), and Page (a live page the agent shows, or one opened from Files).
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { DirectoryEntry } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { replace, route } from "../route";
import { Changes } from "./Changes";
import { FileView } from "./files/FileView";
import { extensionOf, nameOf, paneOf, pathOf, setPane, type Tab } from "./files/paneState";
import { LiveDocument } from "./LiveDocument";

const tabs: { tab: Tab; label: string }[] = [
  { tab: "files", label: "Files" }, { tab: "changes", label: "Changes" }, { tab: "page", label: "Page" },
];

function Browser({ store, host, session, root }: { store: Store; host: string; session: string; root: string }) {
  const pane = paneOf(session);
  const folder = pane.folder ?? root;
  const entries = useSignal<DirectoryEntry[]>([]);
  const failed = useSignal<string | null>(null);
  const changedAt = store.filesChanged.value?.agentID === session ? store.filesChanged.value.at : 0;
  useEffect(() => {
    failed.value = null;
    void store.listFiles(host, session, folder).then(
      (listing) => (entries.value = [...listing.entries].sort((a, b) => Number(b.isDirectory) - Number(a.isDirectory) || a.name.localeCompare(b.name))),
      (e) => { entries.value = []; failed.value = describe(e); });
  }, [host, session, folder, changedAt]);
  useEffect(() => {
    store.watchFolder(host, session, folder);
    return () => store.unwatchFolder(host, session, folder);
  }, [host, session, folder]);

  if (pane.file) {
    const file = pane.file;
    return (
      <div class="file">
        <div class="crumbs">
          <button class="link" onClick={() => setPane(session, { file: undefined })}>‹ {nameOf(folder)}</button>
          <span class="title">{nameOf(file)}</span>
          {(extensionOf(file) === "md" || extensionOf(file) === "markdown") && (
            <button class="link" onClick={() => setPane(session, { tab: "page", page: file, line: undefined })}>Open as Page</button>
          )}
        </div>
        <FileView store={store} host={host} agentID={session} path={file} />
      </div>
    );
  }
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
          return (
            <li key={entry.url}>
              <button class="row entry" onClick={() => setPane(session, entry.isDirectory ? { folder: path } : { file: path })}>
                <span class="title">{entry.isDirectory ? "📁" : "📄"} {entry.name}</span>
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
        {pane.tab === "files" && root && <Browser store={store} host={host} session={session} root={root} />}
        {pane.tab === "changes" && <Changes store={store} host={host} session={session} />}
        {pane.tab === "page" && (pane.page
          ? <LiveDocument store={store} host={host} agentID={session} path={pane.page} line={pane.line} />
          : <p class="hint">A Markdown file the agent shows, or one you open from Files, reads here.</p>)}
      </div>
    </aside>
  );
}
