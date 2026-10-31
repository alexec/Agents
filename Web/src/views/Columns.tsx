// The Mac window's layout in a tab (071 US2, US6; #151, #235). As the window since #145: one
// sidebar (New Session, Activity, the smart groups, a group per folder, the hosts' state at its
// foot; #499), then the chat, a folder's new-session form, a workflow, its archive, an Activity
// page, a change's Review page (#1472), this browser's Settings (#846), or help text with nothing chosen; the files pane a third column from 1440, over the chat below that. Below 760 the same
// sidebar is the root list, as the iPhone Remote's is (#226), and what it picks takes its place,
// with ‹ Agents back to it. Above it all, the bar of sections (#2141): this is Agents; the Overview
// and every other section take the place of the sidebar and the chat.
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import { folderKey } from "../model/groups";
import { replace, route } from "../route";
import { setPane, textShownAs } from "./files/paneState";
import type { Session } from "../session";
import { Banner } from "./Banner";
import { Chat } from "./Chat";
import { NewAgent } from "./NewAgent";
import { NewFolderDialog } from "./NewFolder";
import { DropboxDialog } from "./DropboxDialog";
import { GitLendDialog } from "./GitLend";
import { ExportImportDialog } from "./ExportImport";
import { Problem } from "./Errors";
import { FilesPane } from "./FilesPane";
import { WorkflowPage } from "./WorkflowPage";
import { PinnedPage } from "./Pins";
import { ArchivePage } from "./ArchivePage";
import { MCPServersPage } from "./MCPServers";
import { ReviewPage } from "./Review";
import { Sidebar } from "./Sidebar";
import { ContextMenu } from "./ContextMenu";
import { MilestoneCard } from "./MilestoneCard";
import { NavBar, PageView, SectionPage } from "./Nav";
import { Overview } from "./Overview";
import { navPages } from "../model/nav";
import { sectionOf } from "../route";
import { OrgPolicyStrip } from "./OrgPolicyLine";

export function Columns({ session, store }: { session: Session; store: Store }) {
  const r = route.value;
  const down = session.state.value.kind === "down";
  // What a narrow window shows: the list, or what the route opens in the chat's place.
  const section = sectionOf(r);
  const agentsPage = section === "agents" && !r.host ? navPages.agents.find((p) => p.id === r.section) : undefined;
  const depth = section !== "agents" || agentsPage || r.session || r.workflow || r.page || r.compose || r.archive || r.mcp || r.review ? "chat" : "list";
  const folder = r.host && r.folder
    ? (store.folders.value[r.host] ?? []).find((p) => folderKey(p.folder.folder) === folderKey(r.folder!))
    : undefined;
  useEffect(() => {
    if (r.host && r.session) void store.openSession(r.host, r.session);
    else store.closeSession();
  }, [r.host, r.session]);
  // A file the agent asks to be put in front of the person, beside the open chat (US4 scenario
  // 3): Markdown on the Page, anything else under Files at its line, as the Remote's
  // PaneState.open does; a chart is drawn there (#836). Shown for another session, it waits for that one.
  const shown = store.shownFile.value;
  useEffect(() => {
    if (!shown || shown.host !== r.host || shown.agentID !== r.session) return;
    if (textShownAs(shown.path) === "page") setPane(shown.agentID, { tab: "page", page: shown.path, line: shown.line });
    else setPane(shown.agentID, { tab: "files", file: shown.path, fileLine: shown.line, last: shown.path });
    if (!route.peek().files) replace({ ...route.peek(), files: true });
  }, [shown?.at, r.session]);
  return (
    <div class={`app depth-${depth}${r.files && r.session ? " files-open" : ""}${down ? " down" : ""}`}>
      {down && <Banner session={session} />}
      <Problem store={store} />
      <OrgPolicyStrip store={store} />
      <NavBar store={store} session={session} />
      {section === "overview" ? <div class="columns overview-columns console" aria-busy={down}><Overview store={store} down={down} /></div>
        : section !== "agents" ? <SectionPage store={store} section={section} down={down} /> : <div class="columns with-sidebar" aria-busy={down}>
        <Sidebar session={session} store={store} linkDown={down} />
        {agentsPage ? <PageView store={store} page={agentsPage} down={down} />
          : r.host && r.folder && folder && r.review ? (
            <ReviewPage key={`${r.host}|${r.review}`} store={store} host={r.host} folder={folder.folder.folder} folderName={folder.name}
              id={r.review} down={down || !store.hostIsOnline(r.host)} />
          ) : r.host && r.session ? (store.agent(r.host, r.session)
            ? <Chat store={store} host={r.host} session={r.session} down={down} />
            : <MissingSession store={store} looked={!down && store.hostIsOnline(r.host)
              && store.lookedFor.value?.host === r.host && store.lookedFor.value.session === r.session} />)
          : r.host && r.folder && folder && r.workflow ? (
            <WorkflowPage store={store} host={r.host} folder={folder.folder.folder} folderName={folder.name}
              workflowID={r.workflow} down={down || !store.hostIsOnline(r.host)} />
          ) : r.host && r.folder && folder && r.page ? (
            <PinnedPage store={store} host={r.host} folder={folder.folder.folder} path={r.page} down={down || !store.hostIsOnline(r.host)} />
          ) : r.host && r.folder && folder && r.archive ? (
            <ArchivePage store={store} host={r.host} folder={folder.folder.folder} folderName={folder.name} down={down} />
          ) : r.host && r.folder && folder && r.mcp ? (
            <MCPServersPage store={store} host={r.host} folder={folder.folder.folder} folderName={folder.name} />
          ) : r.host && r.folder && folder && r.compose ? (
            // Only when asked for: leaving a session shows nothing chosen, not New Session (#2090).
            <NewAgent store={store} host={r.host} folder={folder.folder.folder} folderName={folder.name} down={down} />
          ) : <NothingChosen />}
        {r.host && r.session && r.files && <FilesPane store={store} host={r.host} session={r.session} />}
      </div>}
      <NewFolderDialog store={store} />
      <DropboxDialog store={store} />
      <GitLendDialog store={store} />
      <ExportImportDialog store={store} />
      <ContextMenu />
      <MilestoneCard store={store} />
    </div>
  );
}

/**
 * A session chosen that is not in hand (#2652), as the window's ChatView (#2651): a spinner until it has
 * been looked for, then that it was deleted. Never an empty chat to type into, which is New Session's.
 */
/**
 * A session not in hand: deleted only once its host has answered that it is not there (#2652). A lookup that
 * failed says so, with Try Again, as the chat's history does (#400, #2743); until then, on its way.
 */
function MissingSession({ store, looked }: { store: Store; looked: boolean }) {
  const failure = store.transcriptLoadFailure.value;
  if (!looked && failure) {
    return (
      <section class="chat empty session-not-loaded" aria-label="Session did not load">
        <span class="glyph" aria-hidden="true">⚠︎</span>
        <h2>This session did not load</h2>
        <p role="status">{failure.reason}</p>
        <p><button class="link" onClick={() => { void store.reloadTranscript(); }}>Try Again</button></p>
      </section>
    );
  }
  if (!looked) return <section class="chat empty" aria-label="Loading" aria-busy="true"><span class="spinner" aria-hidden="true" /></section>;
  return (
    <section class="chat empty session-deleted" aria-label="Session deleted">
      <span class="glyph" aria-hidden="true">🗑</span>
      <h2>This session was deleted</h2>
      <p>There is nothing left of it to show. Pick another session on the left.</p>
    </section>
  );
}

/** With nothing chosen, what the sidebar is for and its keys, in the window's words (#145). */
function NothingChosen() {
  return (
    <section class="chat empty nothing-chosen" aria-label="Nothing selected">
      <span class="glyph" aria-hidden="true">◧</span>
      <h2>Nothing selected</h2>
      <p>Pick a session on the left to read it, or New Session at the top to start one.</p>
      <p>↑ and ↓ move through the list, → and ← unfold and fold a folder.</p>
    </section>
  );
}
