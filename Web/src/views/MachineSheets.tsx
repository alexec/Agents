// Update…, Choose Folders… and Link to Provider… on a machine's row (#4122), the window's
// ControlAddServerSheet (updating), ChooseFoldersSheet and LinkWorkspaceSheet on the page.
import { useEffect, useState } from "preact/hooks";
import type { ControlMachine, FoldersFindRequest, FoundFolder } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { defaultIdleMinutes, idleChoices, providerWords } from "../model/machineProviders";
import {
  addFoldersTitle, chooseFoldersWords as folderWords, foundName, foundNote, foundPath, linkChoiceLine, linkChoices,
  notAddedLine, updateWords,
} from "../model/machineSheets";
import { Modal } from "./Modal";

export type MachineSheet = "update" | "folders" | "link";

export function MachineSheetDialog({ store, host, sheet, close }: {
  store: Store; host: ControlMachine; sheet: MachineSheet; close: () => void;
}) {
  if (sheet === "update") return <UpdateDialog store={store} host={host} close={close} />;
  if (sheet === "folders") return <ChooseFoldersDialog store={store} host={host} close={close} />;
  return <LinkProviderDialog store={store} host={host} close={close} />;
}

/** Update…: the machine's ssh destination, a new host key to trust first, then the control plane updates it. */
function UpdateDialog({ store, host, close }: { store: Store; host: ControlMachine; close: () => void }) {
  const [destination, setDestination] = useState("");
  const [fingerprint, setFingerprint] = useState<string>();
  const [working, setWorking] = useState(false);
  const [problem, setProblem] = useState<string>();
  const [updated, setUpdated] = useState<string>();
  const update = async () => {
    if (!destination.trim()) return setProblem(updateWords.noDestination);
    setWorking(true);
    setProblem(undefined);
    const outcome = await store.providers.update(host.id, destination.trim(), fingerprint);
    setWorking(false);
    if ("needsTrust" in outcome) return setFingerprint(outcome.needsTrust);
    setFingerprint(undefined);
    if ("failed" in outcome) return setProblem(outcome.failed);
    setUpdated(outcome.updated);
  };
  return (
    <Modal label={updateWords.title(host.name)} close={close} keep={() => working}>
      <div class="sheet-body connect-sheet provider-sheet">
        <p class="strong">{updateWords.title(host.name)}</p>
        {updated ? <p class="small">{updateWords.updated(updated)}</p> : (
          <form class="token-form" onSubmit={(e) => { e.preventDefault(); void update(); }}>
            <p class="small quiet">{updateWords.note(host.name)}</p>
            <label>ssh destination
              <input type="text" value={destination} placeholder="user@server" disabled={working || !!fingerprint}
                autocomplete="off" autocapitalize="off" spellcheck={false}
                onInput={(e) => setDestination((e.target as HTMLInputElement).value)} />
            </label>
          </form>
        )}
        {fingerprint && <p class="small">{updateWords.trustNote(fingerprint)}</p>}
        {working && <p class="quiet small">{updateWords.updating}</p>}
        {problem && <p class="small failure">{problem}</p>}
        <div class="sheet-actions">
          {updated ? <button type="button" class="prominent" onClick={close}>Done</button> : (
            <>
              <button type="button" disabled={working} onClick={close}>Cancel</button>
              <button type="button" class="prominent" disabled={working || !destination.trim()} onClick={() => void update()}>
                {fingerprint ? "Trust and Update" : "Update"}
              </button>
            </>
          )}
        </div>
      </div>
    </Modal>
  );
}

/** Choose Folders…: the git repositories under the control plane's auto-detect paths, each unticked, and any folder typed. */
function ChooseFoldersDialog({ store, host, close }: { store: Store; host: ControlMachine; close: () => void }) {
  const [paths, setPaths] = useState<string[] | null>(null);
  const [looking, setLooking] = useState(true);
  const [found, setFound] = useState<FoundFolder[]>([]);
  const [ticked, setTicked] = useState<ReadonlySet<string>>(new Set());
  const [typed, setTyped] = useState("");
  const [problem, setProblem] = useState<string>();
  const [adding, setAdding] = useState(false);
  const find = (request: FoldersFindRequest) => store.findFolders(host.id, request);
  useEffect(() => {
    let gone = false;
    void (async () => {
      const where = await store.folderPaths();
      if (gone) return;
      setPaths(where);
      if (where.length > 0) {
        try {
          const listed = await find({ paths: where });
          if (!gone) setFound(listed);
        } catch (error) {
          if (!gone) setProblem(folderWords.cantAsk(host.name, describe(error)));
        }
      }
      if (!gone) setLooking(false);
    })();
    return () => { gone = true; };
  }, [host.id]);
  const tick = (path: string, on: boolean) => {
    const next = new Set(ticked);
    if (on) next.add(path); else next.delete(path);
    setTicked(next);
  };
  const addTyped = async () => {
    const text = typed.trim();
    if (!text) return;
    try {
      const folder = (await find({ folders: [text] }))[0];
      if (!folder) return;
      if (!folder.exists) return setProblem(folderWords.noSuch(text, host.name));
      setProblem(undefined);
      setTyped("");
      const path = foundPath(folder);
      if (!found.some((f) => foundPath(f) === path)) setFound([...found, folder]);
      if (!folder.isFolder) setTicked(new Set([...ticked, path]));
    } catch (error) {
      setProblem(folderWords.cantAskAbout(host.name, text, describe(error)));
    }
  };
  const addTicked = async () => {
    const chosen = found.filter((f) => ticked.has(foundPath(f)) && !f.isFolder);
    setAdding(true);
    const failed = await store.addFolders(host.id, chosen.map((f) => f.folder));
    setAdding(false);
    const added = new Set(chosen.filter((f) => !(f.folder in failed)).map(foundPath));
    setFound(found.map((f) => (added.has(foundPath(f)) ? { ...f, isFolder: true } : f)));
    setTicked(new Set([...ticked].filter((p) => !added.has(p))));
    if (Object.keys(failed).length === 0) close();
    else setProblem(notAddedLine(failed));
  };
  return (
    <Modal label={folderWords.title} close={close} keep={() => adding}>
      <div class="sheet-body connect-sheet provider-sheet choose-folders">
        <p class="strong">{folderWords.title}</p>
        {paths && <p class="small quiet">{folderWords.intro(host.name, paths)}</p>}
        {looking ? (
          <p class="small quiet" role="status"><span class="spinner" aria-hidden="true" /> {paths ? folderWords.looking(paths) : "Looking for folders…"}</p>
        ) : found.length === 0 ? (paths && paths.length > 0 && !problem && <p class="small quiet">{folderWords.none(paths)}</p>) : (
            <ul class="found-folders">
              {found.map((f) => {
                const path = foundPath(f);
                return (
                  <li key={path}>
                    <label>
                      <input type="checkbox" checked={f.isFolder || ticked.has(path)} disabled={f.isFolder || adding}
                        aria-label={foundName(f)} onChange={(e) => tick(path, e.currentTarget.checked)} />
                      <span>{foundName(f)}</span>
                      <span class="small quiet path" title={path}>{path}</span>
                      {foundNote(f) && <span class="small quiet">{foundNote(f)}</span>}
                    </label>
                  </li>
                );
              })}
            </ul>
          )}
        <form class="token-form inline" onSubmit={(e) => { e.preventDefault(); void addTyped(); }}>
          <input type="text" value={typed} placeholder={folderWords.placeholder(host.name)} aria-label="Folder"
            autocomplete="off" autocapitalize="off" spellcheck={false} disabled={adding}
            onInput={(e) => setTyped((e.target as HTMLInputElement).value)} />
          <button type="submit" disabled={!typed.trim() || adding}>Add Folder</button>
        </form>
        {problem && <p class="small failure">{problem}</p>}
        <div class="sheet-actions">
          <button type="button" disabled={adding} onClick={close}>Cancel</button>
          <button type="button" class="prominent" disabled={ticked.size === 0 || adding} onClick={() => void addTicked()}>
            {addFoldersTitle(ticked.size)}
          </button>
        </div>
      </div>
    </Modal>
  );
}

/** Link to Provider…: a registered machine linked to a provider's workspace, so the provider starts and stops it. */
function LinkProviderDialog({ store, host, close }: { store: Store; host: ControlMachine; close: () => void }) {
  const providers = store.providers.list.value;
  useEffect(() => { void store.providers.load(); }, []);
  const groups = linkChoices(providers ?? [], store.hosts.value);
  const [chosen, setChosen] = useState<string>();
  const [startWhenUsed, setStartWhenUsed] = useState(true);
  const [idle, setIdle] = useState(defaultIdleMinutes);
  const [fingerprint, setFingerprint] = useState<string>();
  const [working, setWorking] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const choice = groups.flatMap((g) => g.workspaces).find((w) => w.key === chosen);
  const link = async () => {
    if (!choice) return;
    setWorking(true);
    setProblem(null);
    const outcome = await store.providers.link(host.id, choice.provider, choice.workspace.id, startWhenUsed, idle, fingerprint);
    setWorking(false);
    // A machine that joined with the command: its host key, to trust first (#3379).
    if ("needsTrust" in outcome) return setFingerprint(outcome.needsTrust);
    setFingerprint(undefined);
    if ("failed" in outcome) setProblem(outcome.failed);
    else close();
  };
  const title = `Link ${host.name} to a Provider’s Machine`;
  return (
    <Modal label={title} close={close} keep={() => working}>
      <div class="sheet-body connect-sheet provider-sheet">
        <p class="strong">{title}</p>
        {providers === null ? <p class="small quiet">Listing the providers’ machines…</p>
          : groups.length === 0 ? <p class="small">No provider lists a machine. Add a provider in Settings ▸ Machine Providers.</p> : (
            <div class="link-choices" role="radiogroup" aria-label="Provider’s machine">
              {groups.map((g) => (
                <fieldset key={g.provider.id}>
                  <legend class="strong small">{g.provider.name}</legend>
                  {g.workspaces.map((w) => (
                    <label key={w.key} class={w.linkedTo ? "quiet" : undefined}>
                      <input type="radio" name="workspace" checked={chosen === w.key} disabled={!!w.linkedTo || working}
                        onChange={() => { if (chosen !== w.key) setFingerprint(undefined); setChosen(w.key); }} />
                      <span>{w.workspace.name}</span>
                      <span class="small quiet">{linkChoiceLine(w)}</span>
                    </label>
                  ))}
                </fieldset>
              ))}
            </div>
          )}
        <form class="token-form" onSubmit={(e) => { e.preventDefault(); void link(); }}>
          <label class="setting">
            <span>Start when used</span>
            <input type="checkbox" role="switch" checked={startWhenUsed} onChange={(e) => setStartWhenUsed(e.currentTarget.checked)} />
          </label>
          <label>Stop when idle
            <select value={String(idle)} onChange={(e) => setIdle(Number((e.target as HTMLSelectElement).value))}>
              {idleChoices.map((c) => <option key={c.minutes} value={String(c.minutes)}>{c.label}</option>)}
            </select>
          </label>
        </form>
        {fingerprint && <p class="small">{providerWords.linkTrustNote(fingerprint)}</p>}
        {working && <p class="quiet small">{providerWords.linking}</p>}
        {problem && <p class="small failure">{problem}</p>}
        <div class="sheet-actions">
          <button type="button" disabled={working} onClick={close}>Cancel</button>
          <button type="button" class="prominent" disabled={!choice || working} onClick={() => void link()}>
            {fingerprint ? "Trust and Link" : "Link"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
