// Status ▸ Secrets and Status ▸ Accounts (#4161, specs/secret-info §9), as the window's (Shared/UI/UserScope/
// StatusSecretsPage.swift): a list you only read, newest operation first, with the warning under one that is not
// backed up. A press on a row, and the link at the foot, open Settings ▸ You.
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import { go } from "../route";
import { accountLines, newestAt, recentRead, secretLines, shortAgo, statusSecretsWords as w, summary, type StatusLine } from "../model/statusSecrets";

type List = "secrets" | "accounts";

/** A Status list's lines, from what the store last read. */
export function statusLines(store: Store, list: List): StatusLine[] {
  const status = store.userScopeStatus.value;
  if (!status) return [];
  return list === "secrets" ? secretLines(status.secrets) : accountLines(status.accounts, status.secrets);
}

/** Reads the lists when the Status section opens and on each control/userSettingsChanged. */
export function useUserScopeStatus(store: Store, on: boolean) {
  const changes = store.userScopeChanges.value;
  useEffect(() => { if (on) void store.loadUserScopeStatus(); }, [changes, on]);
}

/** The sidebar row's end: the newest operation's age. No warning tint: "not backed up" is on the page. */
export function StatusListMark({ store, list }: { store: Store; list: List }) {
  const at = newestAt(statusLines(store, list));
  return at !== null ? <span class="quiet small" title={new Date(at).toLocaleString()}>{shortAgo(at)}</span> : null;
}

/** Under the sidebar row, in grey, as the window's: the secret or account read last and the session that read it,
 * when that read is the newest operation and less than 4 hours old. */
export function StatusListReadLine({ store, list }: { store: Store; list: List }) {
  const title = (id: string) => Object.values(store.agents.value).flat().find((a) => a.id === id)?.title;
  const read = recentRead(statusLines(store, list), Date.now(), title);
  return read ? <p class="page-need quiet small" aria-label={`${w.readLabel} ${read}`}>{read}</p> : null;
}

export function StatusSecretsPage({ store, list }: { store: Store; list: List }) {
  const lines = statusLines(store, list);
  const open = () => go({ nav: "settings", section: list });
  const now = Date.now();
  return (
    <section aria-label={list === "secrets" ? "Secrets" : "Accounts"}>
      <p class="hint">{list === "secrets" ? w.secretsLead : w.accountsLead}</p>
      {lines.length === 0 && <p class="hint">{list === "secrets" ? w.noSecrets : w.noAccounts}</p>}
      <ul class="user-secrets status-list">
        {lines.map((line) => (
          <li key={line.id} class="user-secret">
            <button type="button" class="status-list-row" onClick={open}>
              <span>{line.title}</span>
              {line.at !== null && <span class="quiet small" title={new Date(line.at).toLocaleString()}>{shortAgo(line.at, now)}</span>}
              <span class="hint">{summary(line)}</span>
              {!line.backedUp && <span class="hint attention">{w.notBackedUp}</span>}
            </button>
          </li>
        ))}
      </ul>
      <button type="button" class="link" onClick={open}>{list === "secrets" ? w.editSecrets : w.editAccounts}</button>
    </section>
  );
}
