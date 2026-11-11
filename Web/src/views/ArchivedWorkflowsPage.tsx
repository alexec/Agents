// A folder's archived workflows (#4451), from its Archived Workflows row in the sidebar, as the Mac's
// ArchivedWorkflowsPage: the same frame as Archived Sessions, the sidebar's workflow rows by name, no
// day groups (a workflow has no archive date) and no Load more (a folder's workflows are all held).
// A row opens the workflow's page, where Unarchive is.
import { useEffect, useState } from "preact/hooks";
import { archivedState, workflowCount, workflowsWords } from "../model/archivedPage";
import { parseQuery } from "../model/labels";
import type { Store } from "../model/store";
import { go } from "../route";
import { ArchivedFooter, ArchivedFrame } from "./ArchivedParts";
import { workflowMatches } from "./Sidebar";
import { WorkflowRow } from "./WorkflowRow";

export function ArchivedWorkflowsPage({ store, host, folder, folderName, down }: {
  store: Store; host: string; folder: string; folderName: string; down: boolean;
}) {
  const online = store.hostIsOnline(host);
  const [filter, setFilter] = useState("");
  // Held while the page is open, and let go when it closes.
  useEffect(() => {
    if (!online) return;
    store.holdWorkflows(host, folder);
    return () => store.releaseWorkflows(host, folder);
  }, [host, folder, online]);
  const words = filter.trim();
  const held = store.folderWorkflows(host, folder).filter((w) => w.isArchived)
    .sort((a, b) => a.workflow.name.localeCompare(b.workflow.name));
  const shown = words ? held.filter(workflowMatches(store, host, parseQuery(words))) : held;
  const state = archivedState(shown.length, !!words, true, !online || down);
  return (
    <ArchivedFrame kind="workflows" title={workflowsWords.title} folderName={folderName} filterLabel={workflowsWords.filter}
      filter={filter} onFilter={setFilter} state={state} noMatch={workflowsWords.noMatch}
      empty={{ mark: "◷", title: workflowsWords.emptyTitle, line: workflowsWords.emptyLine }}>
      {shown.map((summary) => (
        <div class="nav-item" key={summary.workflow.workflowID}>
          <WorkflowRow store={store} host={host} summary={summary} disabled={down || !online} chosen={false}
            onPick={() => go({ host, folder, workflow: summary.workflow.workflowID })} />
        </div>
      ))}
      {!words && <ArchivedFooter words={workflowCount(held.length)} loadingMore={false} />}
    </ArchivedFrame>
  );
}
