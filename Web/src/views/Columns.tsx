// The Mac window's layout in a tab (071 US2, US6; #151, #235). As the window since #145: one
// sidebar (Activity, the projects folding open on their sessions, the hosts' state at its foot),
// then the chat, a project's new-session form, a workflow, an Activity page, or help text with nothing
// chosen; the files pane a third column from 1440, over the chat below that. Below 760 the same
// sidebar is the root list, as the iPhone Remote's is (#226), and what it picks takes its place,
// with ‹ Agents back to it.
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import { folderKey } from "../model/groups";
import { replace, route } from "../route";
import { setPane } from "./files/paneState";
import type { Session } from "../session";
import { Banner } from "./Banner";
import { DiskStrip } from "./DiskStrip";
import { Chat } from "./Chat";
import { RetiredPage } from "./RetiredPage";
import { NewAgent } from "./NewAgent";
import { NewProjectDialog } from "./NewProject";
import { DropboxDialog } from "./DropboxDialog";
import { TokenAskDialog } from "./TokenAsk";
import { Problem } from "./Errors";
import { FilesPane } from "./FilesPane";
import { WorkflowPage } from "./WorkflowPage";
import { PinnedPage } from "./Pins";
import { Sidebar } from "./Sidebar";
import { ActivityPageView } from "./Activity";
import { ContextMenu } from "./ContextMenu";

export function Columns({ session, store }: { session: Session; store: Store }) {
  const r = route.value;
  const down = session.state.value.kind === "down";
  // What a narrow window shows: the list, or what the route opens in the chat's place.
  const depth = r.activity || r.session || r.workflow || r.page || r.compose ? "chat" : "list";
  const project = r.host && r.project
    ? (store.projects.value[r.host] ?? []).find((p) => folderKey(p.project.folder) === folderKey(r.project!))
    : undefined;
  useEffect(() => {
    if (r.host && r.session) void store.openSession(r.host, r.session);
    else store.closeSession();
  }, [r.host, r.session]);
  // A file the agent asks to be put in front of the person: the page beside the open chat,
  // as the window does (US4 scenario 3). Shown for another session, it waits for that one.
  const shown = store.shownFile.value;
  useEffect(() => {
    if (!shown || shown.host !== r.host || shown.agentID !== r.session) return;
    setPane(shown.agentID, { tab: "page", page: shown.path, line: shown.line });
    if (!route.peek().files) replace({ ...route.peek(), files: true });
  }, [shown?.at, r.session]);
  return (
    <div class={`app depth-${depth}${r.files && r.session ? " files-open" : ""}${down ? " down" : ""}`}>
      {down && <Banner session={session} />}
      <DiskStrip store={store} />
      <Problem store={store} />
      <div class="columns with-sidebar" aria-busy={down}>
        <Sidebar session={session} store={store} linkDown={down} />
        {r.activity ? <ActivityPageView store={store} page={r.activity} />
          : r.host && r.session && !store.agent(r.host, r.session) && store.tombstones.value[`${r.host}|${r.session}`]
            ? <RetiredPage tombstone={store.tombstones.value[`${r.host}|${r.session}`]!} />
          : r.host && r.session ? <Chat store={store} host={r.host} session={r.session} down={down} />
          : r.host && r.project && project && r.workflow ? (
            <WorkflowPage store={store} host={r.host} folder={project.project.folder} projectName={project.name}
              workflowID={r.workflow} down={down || !store.hostIsOnline(r.host)} />
          ) : r.host && r.project && project && r.page ? (
            <PinnedPage store={store} host={r.host} folder={project.project.folder} path={r.page} down={down || !store.hostIsOnline(r.host)} />
          ) : r.host && r.project && project ? (
            <NewAgent store={store} host={r.host} folder={project.project.folder} projectName={project.name} down={down} />
          ) : <NothingChosen />}
        {r.host && r.session && r.files && <FilesPane store={store} host={r.host} session={r.session} />}
      </div>
      <NewProjectDialog store={store} />
      <DropboxDialog store={store} />
      <TokenAskDialog store={store} />
      <ContextMenu />
    </div>
  );
}

/** With nothing chosen, what the sidebar is for and its keys, in the window's words (#145). */
function NothingChosen() {
  return (
    <section class="chat empty nothing-chosen" aria-label="Nothing selected">
      <span class="glyph" aria-hidden="true">◧</span>
      <h2>Nothing selected</h2>
      <p>Pick a session on the left to read it, or a project's New session row to start one there.</p>
      <p>↑ and ↓ move through the list, → and ← unfold and fold a project.</p>
    </section>
  );
}
