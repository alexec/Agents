// This browser's Settings (#846), opened from the sidebar's foot, in the chat's place: what the
// window has in Settings ▸ Sidebar. Which smart groups are on is the person's, kept on their
// Mac and the same on every client (#1033). Workspace providers are the control plane's (#1808).
// Versions are the control plane's and each host's (#1748).
// Backups are the person's Mac's, as the window's Settings ▸ Mac draws them (#1810).
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import { smartRows, smartTitles } from "../model/sidebar";
import { setSmartGroup, smartGroupsOn } from "../model/smartGroups";
import { mayArchiveMyChats, mayArchiveMyChatsFooter, setMayArchiveMyChats } from "../model/fileToSeeWords";
import { BackToList } from "./BackToList";
import { gitLendWords, lends } from "../model/gitLending";
import { iconShowsMood, setIconShowsMood } from "../model/iconMood";
import { setShowsThoughts, showsThoughts, thoughtsFooter } from "../model/thoughts";
import { appMissingWords, missingWords, stateWords, versionWords } from "../model/capabilities";
import { ProvidersSection } from "./Providers";
import { backupDetail, backupEveries, backupKeeps, backupsFooter, confirmTitle, everyLabel, restoreMessage,
  restoredWords } from "../model/backups";
import { fromWireDate } from "../protocol/dates";
import type { BackupEvery } from "../protocol/generated";

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

/** Backups (#1810): how often, how many kept, Back Up Now, and Restore for each backup in the folder. The
 * folder is the Mac's disk, so it is chosen on the Mac. */
function BackupsSection({ store }: { store: Store }) {
  const [said, setSaid] = useState<string | null>(null);
  useEffect(() => store.loadBackups(), [store]);
  const state = store.backups.value;
  if (!state) return null;
  const restore = async (id: string, title: string) => {
    if (!confirm(`${title}\n\n${restoreMessage}`)) return;
    setSaid(null);
    const result = await store.restoreBackup(id);
    if (result) setSaid(restoredWords(result));
  };
  const error = said ?? state.lastError;
  return (
    <section aria-labelledby="settings-backups">
      <h2 class="section-head" id="settings-backups">Backups</h2>
      <label class="setting">
        <span>Back up</span>
        <select value={state.settings.every}
          onChange={(e) => void store.configureBackups({ ...state.settings, every: e.currentTarget.value as BackupEvery })}>
          {backupEveries.map((every) => <option key={every} value={every}>{everyLabel(every)}</option>)}
        </select>
      </label>
      <label class="setting">
        <span>Keep</span>
        <select value={String(state.settings.keep)}
          onChange={(e) => void store.configureBackups({ ...state.settings, keep: Number(e.currentTarget.value) })}>
          {backupKeeps.map((n) => <option key={n} value={String(n)}>{n === 1 ? "1 backup" : `${n} backups`}</option>)}
        </select>
      </label>
      <div class="setting"><span>Folder</span><span class="faint small">{state.folder}</span></div>
      <div class="setting">
        <span />
        <button type="button" disabled={state.making} onClick={() => { setSaid(null); void store.makeBackup(); }}>
          {state.making ? "Backing Up…" : "Back Up Now"}
        </button>
      </div>
      {state.backups.map((backup) => (
        <div class="setting" key={backup.id}>
          <span>{fromWireDate(backup.madeAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}
            {" "}<span class="faint small">{backupDetail(backup)}</span></span>
          <button type="button" onClick={() => void restore(backup.id, confirmTitle(backup))}>Restore…</button>
        </div>
      ))}
      {error && <p class="hint">{error}</p>}
      <p class="hint">{backupsFooter}</p>
    </section>
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
        </div>
      </div>
    </section>
  );
}
