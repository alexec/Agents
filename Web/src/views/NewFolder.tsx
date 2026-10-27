// New folder (#115), as the window's folders column has it (FolderListView, CloneSheet,
// RemoteFolderSheet): Add Folder…, chosen from the host's folders over `files/browse`, and Clone
// Git URL…, on the host the folder is for. The browser can't see the host's disk, so every host's
// folder is chosen the way the window chooses a server's.
import { signal, useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { ControlMachine, DirectoryEntry, DirectoryListing, RuntimeStatus } from "../protocol/generated";
import type { Store } from "../model/store";
import { gitRemote } from "../model/gitRemote";
import { hostAnswers } from "../model/capabilities";
import { describe } from "../model/errors";
import { emptyListRuntimeLine, noAgentRuntime } from "../model/runtimes";
import { isSafeLink } from "../render/markdown";
import { go } from "../route";
import { Modal } from "./Modal";
import { MachineDialog } from "./MachineDialog";
import { machineWords } from "../model/machineFromRepository";

type Adding = { kind: "folder" | "clone"; host: string } | { kind: "machine" };

/** The dialog open now, if any: one at a time, from the + menu, the empty list or the folders menu. */
const adding = signal<Adding | null>(null);

/** "This Mac" for the host on this Mac; otherwise its name, as the window labels them. */
export function hostLabel(store: Store, host: string): string {
  return store.isMac(host) ? "This Mac" : store.hosts.value.find((h) => h.id === host)?.name ?? host;
}

/** The window's menu item for a host that can't be asked: "This Mac — Not answering", a server's "— Offline". */
function hostItem(host: ControlMachine, macID: string): string {
  if (hostAnswers(host.state)) return host.id === macID ? "This Mac" : host.name;
  return host.id === macID ? "This Mac — Not answering" : `${host.name} — Offline`;
}

/**
 * Add Folder… and Clone Folder from Git URL…, per host: under each host's name when there is more than one,
 * as the window's + menu has a submenu per machine. A host that isn't answering can't take one.
 */
export function NewFolderItems({ store, onChoose }: { store: Store; onChoose?: () => void }) {
  const hosts = store.hosts.value;
  const choose = (kind: "folder" | "clone", host: string) => {
    onChoose?.();
    adding.value = { kind, host };
  };
  return (
    <>
      {hosts.map((host) => {
        const offline = !hostAnswers(host.state);
        return (
          <div class="new-folder-host" role="group" aria-label={hostItem(host, store.macHostID.value)} key={host.id}>
            {hosts.length > 1 && <p class="menu-head">{hostItem(host, store.macHostID.value)}</p>}
            <button role="menuitem" disabled={offline} onClick={() => choose("folder", host.id)}>Add Folder…</button>
            <button role="menuitem" disabled={offline} onClick={() => choose("clone", host.id)}>Clone Folder from Git URL…</button>
          </div>
        );
      })}
    </>
  );
}

/** The + at the head of the folders column: the window's toolbar button over its sidebar. */
export function NewFolderMenu({ store, newSession }: { store: Store; newSession?: (() => void) | undefined }) {
  const open = useSignal(false);
  const anchor = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open.value) return;
    const close = (e: Event) => { if (!anchor.current?.contains(e.target as Node)) open.value = false; };
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") open.value = false; };
    addEventListener("pointerdown", close);
    addEventListener("keydown", escape);
    return () => { removeEventListener("pointerdown", close); removeEventListener("keydown", escape); };
  }, [open.value]);
  return (
    <span class="menu-anchor new-folder" ref={anchor}>
      <button class="icon" aria-label="New folder" title="New Session, or Add Folder… or Clone Folder from Git URL… as a folder"
        aria-haspopup="menu" aria-expanded={open.value} onClick={() => (open.value = !open.value)}>+</button>
      {open.value && (
        <div class="popover right" role="menu" aria-label="New folder">
          {/* As the sidebar's top row starts one, in the folder last started in (#628). */}
          <button role="menuitem" disabled={!newSession} onClick={() => { open.value = false; newSession?.(); }}>New Session</button>
          <NewFolderItems store={store} onChoose={() => (open.value = false)} />
          {/* A machine of its own for a repository (#1809), made by a machine provider. */}
          <button role="menuitem" onClick={() => { open.value = false; adding.value = { kind: "machine" }; }}>{machineWords.menuItem}</button>
        </div>
      )}
    </span>
  );
}

/**
 * The first thing a fresh control plane shows: what to do, not that something is wrong. Only
 * once every host that answers has listed its folders, and none has any. When this Mac has
 * answered and nothing there can start, it says so instead, as the window's empty list does
 * (#257). Install stays on the Mac.
 */
export function EmptyFolders({ store }: { store: Store }) {
  // No machine at all, as a control plane started in a browser has (#1809): start one from a repository.
  if (store.plane.value && store.hosts.value.length === 0) {
    return (
      <div class="empty-folders">
        <p class="strong">No machines yet</p>
        <p class="quiet">A machine runs your agents. Start one from a repository with a machine provider.</p>
        <div class="empty-actions">
          <button class="prominent" onClick={() => (adding.value = { kind: "machine" })}>{machineWords.menuItem}</button>
        </div>
      </div>
    );
  }
  return <FoldersEmpty store={store} />;
}

function FoldersEmpty({ store }: { store: Store }) {
  const online = store.hosts.value.filter((h) => hostAnswers(h.state));
  const listed = online.every((h) => store.folders.value[h.id] !== undefined);
  // Archived ones are listed too (#343), and are not folders to work in.
  const none = online.every((h) => (store.folders.value[h.id] ?? []).every((p) => p.folder.archivedAt !== undefined)
    && (store.clones.value[h.id] ?? []).length === 0);
  const showing = online.length > 0 && listed && none;
  const macID = store.macHostID.value;
  const macOnline = online.some((h) => h.id === macID);
  const macListed = macOnline && store.runtimes.value[macID] !== undefined;
  // A list that failed is not "no runtime": the add-folder prompt stays, and the next look tries again.
  const failed = useSignal(false);
  useEffect(() => {
    if (!showing || !macOnline) return;
    let live = true;
    if (!macListed) {
      failed.value = false;
      void store.loadRuntimes(macID).finally(() => {
        if (live && store.runtimes.peek()[macID] === undefined) failed.value = true;
      });
    }
    // An install on the Mac shows up when the page is shown again: the page is not told runtime/changed.
    const onVis = () => { if (document.visibilityState === "visible") void store.loadRuntimes(macID); };
    document.addEventListener("visibilitychange", onVis);
    return () => { live = false; document.removeEventListener("visibilitychange", onVis); };
  }, [showing, macID, macOnline, macListed]);
  if (!showing) return null;
  const macRuntimes = macOnline ? store.runtimes.value[macID] : undefined;
  // Held until this Mac's list arrives, so "No folders yet" does not flash in its place.
  if (macOnline && macRuntimes === undefined && !failed.value) return null;
  if (noAgentRuntime(macRuntimes)) return <NoAgentRuntime runtimes={macRuntimes ?? []} />;
  // On this Mac when it answers, as the window's empty list adds to this Mac.
  const host = online.find((h) => h.id === macID)?.id ?? online[0]!.id;
  return (
    <div class="empty-folders">
      <p class="strong">No folders yet</p>
      <p class="quiet">Pick a folder and say what you want done.</p>
      <div class="empty-actions">
        <button class="prominent" onClick={() => (adding.value = { kind: "folder", host })}>Add Folder…</button>
        <button onClick={() => (adding.value = { kind: "clone", host })}>Clone Folder from Git URL…</button>
      </div>
    </div>
  );
}

/** Nothing on this Mac can start: the window's words, and each runtime's standing. */
function NoAgentRuntime({ runtimes }: { runtimes: RuntimeStatus[] }) {
  return (
    <div class="empty-folders">
      <p class="strong">No agent runtime found</p>
      <p class="quiet">Agents runs the coding CLIs on this Mac. Install one on the Mac, in Settings ▸ Agent Runtimes, or from its own page.</p>
      {runtimes.length > 0 && (
        <ul class="empty-runtimes">
          {runtimes.map((status) => {
            const row = emptyListRuntimeLine(status);
            return (
              <li key={status.runtime.id}>
                <span class="strong">{status.runtime.name}</span>
                {row.line && <span class={row.failed ? "small failure" : "quiet small"}>{row.line}</span>}
                {row.page && isSafeLink(row.page) && (
                  <a href={row.page} target="_blank" rel="noopener noreferrer">Open install page</a>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

/** Whichever dialog is open. Drawn once, by the columns. */
export function NewFolderDialog({ store }: { store: Store }) {
  const open = adding.value;
  if (!open) return null;
  const close = () => (adding.value = null);
  if (open.kind === "machine") return <MachineDialog store={store} close={close} />;
  return open.kind === "folder"
    ? <FolderDialog key={`folder-${open.host}`} store={store} host={open.host} close={close} />
    : <CloneDialog key={`clone-${open.host}`} store={store} host={open.host} close={close} />;
}

/** The path of a `file://` URL, as the field shows it. */
function pathOf(url: string): string {
  try {
    return decodeURIComponent(new URL(url).pathname);
  } catch {
    return url;
  }
}

/** The folder above `path`, or null at the top. */
function parentOf(path: string): string | null {
  const trimmed = path.replace(/\/+$/, "");
  if (!trimmed) return null;
  return trimmed.slice(0, trimmed.lastIndexOf("/")) || "/";
}

/** Folders first, then files, each by name (RemoteFolderSheet.entries). */
function ordered(entries: DirectoryEntry[]): DirectoryEntry[] {
  return [...entries].sort((a, b) => a.isDirectory !== b.isDirectory ? (a.isDirectory ? -1 : 1)
    : a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }));
}

/** Choose a folder on a host as a folder (RemoteFolderSheet): a path field, and the folders under it. */
function FolderDialog({ store, host, close }: { store: Store; host: string; close: () => void }) {
  const label = hostLabel(store, host);
  const path = useSignal("~");
  const listing = useSignal<DirectoryListing | null>(null);
  const chosen = useSignal<string | null>(null);
  const problem = useSignal<string | null>(null);
  const load = async (wanted: string) => {
    try {
      const listed = await store.browse(host, wanted);
      listing.value = listed;
      path.value = pathOf(listed.url);
      chosen.value = null;
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
  };
  useEffect(() => { void load("~"); }, []);
  const parent = listing.value ? parentOf(pathOf(listing.value.url)) : null;
  const add = async () => {
    const folder = chosen.value ?? listing.value?.url;
    close();
    if (!folder) return;
    const summary = await store.addFolder(host, folder);
    if (summary) go({ host, folder: summary.folder.folder, compose: true });
  };
  return (
    <Modal label={`Choose a folder on ${label}`} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void load(path.value); }}>
        <h2>Choose a folder on {label}</h2>
        <input type="text" aria-label="Folder" placeholder="~/src" value={path.value} spellcheck={false}
          onInput={(e) => (path.value = (e.currentTarget as HTMLInputElement).value)} />
      </form>
      <div class="folder-list" role="listbox" aria-label={`Folders on ${label}`}>
        {parent !== null && (
          <button type="button" class="folder-row up" role="option" aria-selected={false}
            onClick={() => void load(parent)}>‹ {parent === "/" ? "/" : parent.slice(parent.lastIndexOf("/") + 1)}</button>
        )}
        {ordered(listing.value?.entries ?? []).map((entry) => (
          <button type="button" key={entry.url} role="option" aria-selected={chosen.value === entry.url}
            class={`folder-row${entry.isDirectory ? "" : " file"}${chosen.value === entry.url ? " chosen" : ""}`}
            disabled={!entry.isDirectory}
            onClick={() => (chosen.value = entry.url)}
            onDblClick={() => void load(pathOf(entry.url))}>{entry.name}</button>
        ))}
      </div>
      {problem.value
        ? <p class="sheet-note failure" role="alert">{problem.value}</p>
        : <p class="sheet-note">Type a path or click into a folder. Files are shown but can’t be chosen.</p>}
      <div class="sheet-actions">
        <button type="button" onClick={close}>Cancel</button>
        <button type="button" class="prominent" disabled={!listing.value} onClick={() => void add()}>Add as folder</button>
      </div>
    </Modal>
  );
}

/** New folder from a Git URL (CloneSheet): paste it, see where it will go, clone. */
function CloneDialog({ store, host, close }: { store: Store; host: string; close: () => void }) {
  const text = useSignal("");
  const remote = gitRemote(text.value);
  const clone = () => {
    if (!remote) return;
    // Closed as the clone begins: how it goes is a row in the folders column (027).
    close();
    void store.cloneFolder(host, remote.url).then((summary) => {
      if (summary) go({ host, folder: summary.folder.folder, compose: true });
    });
  };
  const note = remote
    ? (store.isMac(host) ? `Clones into ~/${remote.folderName} and adds it as a folder.`
      : `Clones into ~/${remote.folderName} on ${hostLabel(store, host)} and adds it as a folder.`)
    : !text.value.trim() ? "Paste an HTTPS or SSH address."
    : "That is not a Git URL this app can clone. Paste an HTTPS or SSH address.";
  return (
    <Modal label="Clone a Git repository" close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); clone(); }}>
        <h2>Clone a Git repository</h2>
        <input type="text" aria-label="Git URL" placeholder="https://github.com/owner/repository.git" autofocus
          spellcheck={false} value={text.value} onInput={(e) => (text.value = (e.currentTarget as HTMLInputElement).value)} />
        <p class={`sheet-note${remote || !text.value.trim() ? "" : " failure"}`}>{note}</p>
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={!remote}>Clone</button>
        </div>
      </form>
    </Modal>
  );
}

/** A clone under way, where the folder it becomes will be (CloningRow). */
export function CloningRows({ store, host }: { store: Store; host: string }) {
  return (
    <>
      {(store.clones.value[host] ?? []).map((clone) => {
        const name = pathOf(clone.folder).replace(/\/+$/, "").split("/").pop() ?? clone.url;
        return (
          <div class="row folder cloning" key={clone.id} title={clone.url} role="status"
            aria-label={`Cloning ${name} from ${clone.url}`}>
            <span class="title">{name}</span>
            <span class="subtitle">Cloning…</span>
            <span class="spinner" aria-hidden="true" />
          </div>
        );
      })}
    </>
  );
}
