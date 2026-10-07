// The project Dashboard row's page (#188): ui://agents/dashboard, through the same view host a
// chat uses. The native tile page is not this destination. Update now, the file note and the
// footer stay here, around the view.
import { useEffect, useLayoutEffect, useMemo, useRef } from "preact/hooks";
import type { Store } from "../model/store";
import { folderKey } from "../model/groups";
import type { AppViewCall, DashboardSnapshot, JSONValue, UUID } from "../protocol/generated";
import { go } from "../route";
import { BackToList } from "./BackToList";
import { ViewLayer, type ViewActions } from "./chat/viewLayer";

const dashboardURI = "ui://agents/dashboard";

/** The host-made call. A page tile's file changing bumps `pageRevision`, so the result is said
 * again and the view reads its pages afresh (#329). */
export function dashboardCall(id: UUID, snapshot: DashboardSnapshot | undefined, pageRevision = 0): AppViewCall {
  const result: JSONValue | undefined = snapshot
    ? { content: [{ type: "text", text: "Dashboard" }], structuredContent: snapshot as unknown as JSONValue,
        _meta: { "agents/pageRevision": pageRevision } }
    : undefined;
  return {
    id, server: "agents", tool: "read_dashboard", resourceUri: dashboardURI,
    state: snapshot ? "done" : "running",
    ...(result ? { result } : {}),
  };
}

export function DashboardAppView({ store, host, folder, down }: {
  store: Store; host: string; folder: string; down: boolean;
}) {
  useEffect(() => {
    void store.openDashboard(host, folder);
    return () => store.closeDashboard(host, folder);
  }, [host, folder]);
  const key = `${host}|${folderKey(folder)}`;
  const snapshot = store.dashboards.value[key];
  const place = `${host}|${folderKey(folder)}`;
  const layer = useMemo(() => new ViewLayer(), [place]);
  const id = useMemo(() => crypto.randomUUID() as UUID, [place]);
  const actions = useMemo<ViewActions>(() => ({
    agentID: id,
    project: folder,
    openDashboardTarget: (kind, target) => {
      if (kind === "agent") go({ host, project: folder, session: target });
      if (kind === "workflow") go({ host, project: folder, workflow: target });
      if (kind === "page") go({ host, project: folder, page: target });
    },
    call: (method, params) => store.link.call(method, params as never, host) as Promise<unknown>,
    send: async () => false,
  }), [id, host, store]);
  const call = dashboardCall(id, snapshot, store.pageRevisions.value[key] ?? 0);
  const frame = useRef<HTMLDivElement>(null);
  useEffect(() => () => { void layer.tearDownAll("The Dashboard was closed."); }, [layer]);
  useEffect(() => () => layer.stop(), [layer]);
  useLayoutEffect(() => {
    const box = frame.current;
    layer.scroller = box;
    layer.chat = box;
    layer.view(call, actions);
    layer.setFullscreen(call.id);
    layer.sync();
  });
  return (
    <section class="chat dashboard-page" aria-label="Dashboard">
      <header class="column-head">
        <BackToList />
        <h1>Dashboard</h1>
        <span class="actions">
          <button class="icon" aria-label="New session" title="Start a new session in this project" disabled={down}
            onClick={() => go({ host, project: folder, compose: true })}>✎</button>
        </span>
      </header>
      <div class="scroll dashboard-host" ref={frame}>
        <div class="view-layer" ref={(el) => { layer.element = el; }} />
      </div>
    </section>
  );
}
