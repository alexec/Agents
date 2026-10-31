// What one folder has archived (#499), the window's FolderWorkPage and the Remote's ArchivePage
// (#495, #498): its archived sessions, then its workflows, in their order (#547). They used to be
// folds inside the folder's fold in the sidebar; one Archived row there now opens this, so the
// sidebar is never more than two levels deep. The sidebar's own rows, each opening its chat or
// page, with their menus: Unarchive among them.
import { useEffect } from "preact/hooks";
import { archivedPage, type Store } from "../model/store";
import { route, go } from "../route";
import { BackToList } from "./BackToList";
import { SidebarSession } from "./Sidebar";
import { WorkflowRow } from "./WorkflowRow";

export function ArchivePage({ store, host, folder, folderName, down }: {
  store: Store; host: string; folder: string; folderName: string; down: boolean;
}) {
  const online = store.hostIsOnline(host);
  // Held while the page is open, and let go when it closes, as the fold's were.
  useEffect(() => {
    if (!online) return;
    void store.loadArchived(host, folder, archivedPage);
    store.holdWorkflows(host, folder);
    return () => {
      // A session opened from here is watched before the page lets the rest go, so it stays.
      const next = route.peek();
      if (next.host === host && next.session) store.watch(host, next.session);
      store.unloadArchived(host, folder, archivedPage);
      store.releaseWorkflows(host, folder);
    };
  }, [host, folder, online]);
  const sessions = store.folderView(host, folder).archived.slice(0, archivedPage);
  const workflows = store.folderWorkflows(host, folder).filter((w) => w.isArchived)
    .sort((a, b) => a.workflow.name.localeCompare(b.workflow.name));
  const counted = store.folders.value[host]?.find((p) => p.folder.folder === folder)?.counts.archived ?? 0;
  return (
    <section class="chat archive-page" aria-label={`${folderName}: Archived`}>
      <header class="column-head"><BackToList /><h1>Archived</h1><span class="quiet">{folderName}</span></header>
      <div class="scroll">
        <div class="archive-body sessions">
          {sessions.length > 0 && <h2 class="subhead">Sessions</h2>}
          {sessions.map((agent) => (
            <SidebarSession key={agent.id} store={store} host={host} folder={folder} agent={agent} chosen={false}
              down={down || !online} />
          ))}
          {counted > sessions.length && sessions.length === archivedPage && (
            <p class="hint">The newest {archivedPage} of {counted}. Search to find an older one.</p>
          )}
          {workflows.length > 0 && <h2 class="subhead">Workflows</h2>}
          {workflows.map((summary) => (
            <div class="nav-item" key={summary.workflow.workflowID}>
              <WorkflowRow store={store} host={host} summary={summary} disabled={down || !online} chosen={false}
                onPick={() => go({ host, folder: folder, workflow: summary.workflow.workflowID })} />
            </div>
          ))}
          {sessions.length === 0 && workflows.length === 0 && <p class="hint">{online ? "Nothing archived" : "Its machine isn’t answering"}</p>}
        </div>
      </div>
    </section>
  );
}
