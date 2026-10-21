// This browser's Settings (#846), opened from the sidebar's foot, in the chat's place: what the
// window has in Settings ▸ Sidebar. Which smart groups are on is the person's, kept on their
// Mac and the same on every client (#1033). Workspace providers are the control plane's (#1808).
// Versions are the control plane's and each host's (#1748).
// Backups are the person's Mac's, as the window's Settings ▸ Mac draws them (#1810), and each server's (#1815).
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import { smartRows, smartTitles } from "../model/sidebar";
import { setSmartGroup, smartGroupsOn } from "../model/smartGroups";
import { mayArchiveMyChats, mayArchiveMyChatsFooter, setMayArchiveMyChats } from "../model/fileToSeeWords";
import { BackToList } from "./BackToList";
import { gitLendWords, lends } from "../model/gitLending";
import { iconShowsMood, setIconShowsMood } from "../model/iconMood";
import { setShowsThoughts, showsThoughts, thoughtsFooter } from "../model/thoughts";
import { appMissingWords, hostAnswers, hostHas, missingWords, stateWords, versionWords } from "../model/capabilities";
import { ProvidersSection } from "./Providers";
import { backupDetail, backupEveries, backupKeeps, backupTarget, backupTargets, confirmTitle, everyLabel, footerWords,
  restoreMessage, restoredWords, targetLabel } from "../model/backups";
import { fromWireDate } from "../protocol/dates";
import { Capability } from "../protocol/capabilities.generated";
import type { BackupEvery, BackupRestoreResult, BackupSettings, BackupState, BackupTarget } from "../protocol/generated";

/** The words under the Sidebar section, as the window's and the Remote's (#846). */
export const sidebarSettingsFooter = "A group that is off is not shown. Its sessions go to the next group they fit, "
  + "or under their project. With Needs You off, approvals are not listed in the sidebar.";

/** The words under the icon's mood (#1317), for this tab's favicon. */
export const iconMoodFooter = "The Blob on this tab sleeps when nothing runs, smiles while agents work, and looks "
  + "puzzled when a question waits. Off, it always smiles.";

/** Git access (#1122): each host using a Mac's git access for a git server, with Stop Lending. */
function GitAccessSection({ store }: { store: Store }) {
  const lent = lends(store.hosts.value);
  if (lent.length === 0) return null;
  return (
    <section aria-labelledby="settings-git">
      <h2 class="section-head" id="settings-git">Git access</h2>
      <p class="hint">{gitLendWords.footer}</p>
      {lent.map((lend) => (
        <div class="setting" key={`${lend.host} ${lend.server}`}>
          <span>{lend.hostName} · {lend.server} <span class="faint small">Uses {lend.lenderName}’s git access</span></span>
          <button type="button" onClick={() => void store.lendGit(lend.host, lend.from, lend.server, false)}>Stop Lending</button>
        </div>
      ))}
    </section>
  );
}

/** Versions (#1748): the control plane's and each host's, as the window's Control plane pane says them. */
function VersionsSection({ store }: { store: Store }) {
  const plane = store.plane.value;
  if (!plane?.version) return null;
  const appMissing = appMissingWords(plane.required, plane.version);
  return (
    <section aria-labelledby="settings-versions">
      <h2 class="section-head" id="settings-versions">Versions</h2>
      <div class="setting"><span>{plane.name ?? "Control plane"}</span><span class="faint">agents-control {plane.version}</span></div>
      {appMissing && <p class="hint failure">{appMissing}</p>}
      {store.hosts.value.filter((h) => h.relay == null).map((host) => {
        const missing = missingWords(host, plane.version);
        return (
          <div class="setting" key={host.id}>
            <span>{host.name}{missing && <span class="small failure"> {missing}</span>}</span>
            <span class="faint">{host.state === "online" ? "" : `${stateWords(host)} · `}{versionWords(host)}</span>
          </div>
        );
      })}
    </section>
  );
}

/** Backups (#1810): how often, how many kept, where, Back Up Now, and Restore for each backup there. The
 * Mac's folder is its disk, so it is chosen on the Mac. A server's page draws the same (#1815). */
function BackupsView({ state, title, id, configure, make, restore }: {
  state: BackupState;
  title: string;
  id: string;
  configure: (settings: BackupSettings) => void;
  make: () => void;
  restore: (backupID: string) => Promise<BackupRestoreResult | null>;
}) {
  const [said, setSaid] = useState<string | null>(null);
  const restoreOne = async (backupID: string, confirmWords: string) => {
    if (!confirm(`${confirmWords}\n\n${restoreMessage}`)) return;
    setSaid(null);
    const result = await restore(backupID);
    if (result) setSaid(restoredWords(result));
  };
  const error = said ?? state.lastError;
  return (
    <section aria-labelledby={id}>
      <h2 class="section-head" id={id}>{title}</h2>
      <label class="setting">
        <span>Back up</span>
        <select value={state.settings.every}
          onChange={(e) => configure({ ...state.settings, every: e.currentTarget.value as BackupEvery })}>
          {backupEveries.map((every) => <option key={every} value={every}>{everyLabel(every)}</option>)}
        </select>
      </label>
      <label class="setting">
        <span>Keep</span>
        <select value={String(state.settings.keep)}
          onChange={(e) => configure({ ...state.settings, keep: Number(e.currentTarget.value) })}>
          {backupKeeps.map((n) => <option key={n} value={String(n)}>{n === 1 ? "1 backup" : `${n} backups`}</option>)}
        </select>
      </label>
      {state.canUseControl && (
        <label class="setting">
          <span>Back up to</span>
          <select value={backupTarget(state)}
            onChange={(e) => configure({ ...state.settings, target: e.currentTarget.value as BackupTarget })}>
            {backupTargets.map((target) => <option key={target} value={target}>{targetLabel(target)}</option>)}
          </select>
        </label>
      )}
      {backupTarget(state) === "folder" && (
        <div class="setting"><span>Folder</span><span class="faint small">{state.folder}</span></div>
      )}
      <div class="setting">
        <span />
        <button type="button" disabled={state.making} onClick={() => { setSaid(null); make(); }}>
          {state.making ? "Backing Up…" : "Back Up Now"}
        </button>
      </div>
      {state.backups.map((backup) => (
        <div class="setting" key={backup.id}>
          <span>{fromWireDate(backup.madeAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}
            {" "}<span class="faint small">{backupDetail(backup)}</span></span>
          <button type="button" onClick={() => void restoreOne(backup.id, confirmTitle(backup))}>Restore…</button>
        </div>
      ))}
      {error && <p class="hint">{error}</p>}
      <p class="hint">{footerWords(state)}</p>
    </section>
  );
}

/** The person's Mac's backups (#1810), kept up by its backups/changed. */
function BackupsSection({ store }: { store: Store }) {
  useEffect(() => store.loadBackups(), [store]);
  const state = store.backups.value;
  if (!state) return null;
  return (
    <BackupsView state={state} title="Backups" id="settings-backups"
      configure={(settings) => void store.configureBackups(settings)} make={() => void store.makeBackup()}
      restore={(id) => store.restoreBackup(id)} />
  );
}

/** One server's backups (#1815), sent to that host. Its state is held here, read when it opens and after
 * each change, and read again every few seconds while a backup is made: only the Mac's backups/changed is kept. */
function ServerBackups({ store, host, name }: { store: Store; host: string; name: string }) {
  const [state, setState] = useState<BackupState | null>(null);
  const [asked, setAsked] = useState(false);
  const read = () => void store.hostBackups(host).then((s) => { setState(s); setAsked(true); });
  useEffect(read, [store, host]);
  useEffect(() => {
    if (!state?.making) return undefined;
    const timer = setInterval(read, 3_000);
    return () => clearInterval(timer);
  }, [state?.making]);
  const keep = (next: BackupState | null) => { if (next) setState(next); };
  if (!state) return asked ? <p class="hint">{name} can’t be asked about its backups now.</p> : null;
  return (
    <BackupsView state={state} title={`Backups of ${name}`} id={`settings-backups-${host}`}
      configure={(settings) => void store.configureBackups(settings, host).then(keep)}
      make={() => void store.makeBackup(host).then(keep)}
      restore={(id) => store.restoreBackup(id, host)} />
  );
}

/** Servers' Backups (#1815): a row for each server that answers now, opening its backups, as the window opens
 * them from the host's menu and the Remote from its own Settings. */
function ServerBackupsSection({ store }: { store: Store }) {
  const [open, setOpen] = useState<string | null>(null);
  const hosts = store.hosts.value;
  const servers = hosts.filter((h) => h.relay == null && !store.isMac(h.id) && hostAnswers(h.state)
    && hostHas(hosts, h.id, Capability.backups1));
  if (servers.length === 0) return null;
  const shown = servers.find((h) => h.id === open);
  return (
    <>
      <section aria-labelledby="settings-server-backups">
        <h2 class="section-head" id="settings-server-backups">Servers' Backups</h2>
        {servers.map((host) => (
          <div class="setting" key={host.id}>
            <span>{host.name}</span>
            <button type="button" aria-expanded={open === host.id}
              onClick={() => setOpen(open === host.id ? null : host.id)}>{open === host.id ? "Hide" : "Backups…"}</button>
          </div>
        ))}
      </section>
      {shown && <ServerBackups key={shown.id} store={store} host={shown.id} name={shown.name} />}
    </>
  );
}

export function SettingsPage({ store }: { store: Store }) {
  const on = smartGroupsOn.value;
  return (
    <section class="chat activity-page settings-page" aria-label="Settings">
      <header class="column-head"><BackToList /><h1>Settings</h1></header>
      <div class="scroll">
        <div class="activity-body settings-body">
          <section aria-labelledby="settings-appearance">
            <h2 class="section-head" id="settings-appearance">Appearance</h2>
            <label class="setting">
              <span>Icon shows what agents are doing</span>
              <input type="checkbox" role="switch" checked={iconShowsMood.value}
                onChange={(e) => setIconShowsMood(e.currentTarget.checked)} />
            </label>
            <p class="hint">{iconMoodFooter}</p>
            <label class="setting">
              <span>Show thoughts</span>
              <input type="checkbox" role="switch" checked={showsThoughts.value}
                onChange={(e) => setShowsThoughts(e.currentTarget.checked)} />
            </label>
            <p class="hint">{thoughtsFooter}</p>
          </section>
          <section aria-labelledby="settings-sidebar">
            <h2 class="section-head" id="settings-sidebar">Sidebar</h2>
            {smartRows.map((row) => (
              <label class="setting" key={row}>
                <span>{smartTitles[row]}</span>
                <input type="checkbox" role="switch" checked={on.has(row)}
                  onChange={(e) => setSmartGroup(row, e.currentTarget.checked)} />
              </label>
            ))}
            <p class="hint">{sidebarSettingsFooter}</p>
          </section>
          <section aria-labelledby="settings-finished">
            <h2 class="section-head" id="settings-finished">Finished chats</h2>
            <label class="setting">
              <span>Agents may archive the chats I start</span>
              <input type="checkbox" role="switch" checked={mayArchiveMyChats.value}
                onChange={(e) => setMayArchiveMyChats(e.currentTarget.checked)} />
            </label>
            <p class="hint">{mayArchiveMyChatsFooter}</p>
          </section>
          <ProvidersSection store={store} />
          <GitAccessSection store={store} />
          <VersionsSection store={store} />
          <BackupsSection store={store} />
          <ServerBackupsSection store={store} />
        </div>
      </div>
    </section>
  );
}
