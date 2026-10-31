// Settings ▸ You ▸ Backups (#1810) and Machines' Backups (#1815). Listed in ./sections.ts.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../../model/store";
import { hostAnswers, hostHas } from "../../model/capabilities";
import { backupDetail, backupEveries, backupKeeps, backupTarget, backupTargets, confirmTitle, everyLabel, footerWords,
  restoreMessage, restoredWords, sameDiskWords, targetLabel } from "../../model/backups";
import { fromWireDate } from "../../protocol/dates";
import { Capability } from "../../protocol/capabilities.generated";
import type { BackupEvery, BackupRestoreResult, BackupSettings, BackupState, BackupTarget } from "../../protocol/generated";

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
      <h3 class="section-head" id={id}>{title}</h3>
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
      {sameDiskWords(state) && <p class="hint attention">{sameDiskWords(state)}</p>}
      <p class="hint">{footerWords(state)}</p>
    </section>
  );
}

/** The person's Mac's backups (#1810), kept up by its backups/changed. */
export function BackupsSection({ store }: { store: Store }) {
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

/** Machines' Backups (#1815): a row for each server that answers now, opening its backups, as the window opens
 * them from the host's menu and the Remote from its own Settings. */
export function ServerBackupsSection({ store }: { store: Store }) {
  const [open, setOpen] = useState<string | null>(null);
  const hosts = store.hosts.value;
  const servers = hosts.filter((h) => h.relay == null && !store.isMac(h.id) && hostAnswers(h.state)
    && hostHas(hosts, h.id, Capability.backups1));
  if (servers.length === 0) return null;
  const shown = servers.find((h) => h.id === open);
  return (
    <>
      <section aria-labelledby="settings-server-backups">
        <h3 class="section-head" id="settings-server-backups">Machines' Backups</h3>
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
