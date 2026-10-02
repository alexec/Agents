// The Mac window's layout in a tab (071 US2, US6; frames A–D): projects under host headings,
// the chosen project's sessions, and the chosen session's chat with the prompt at its foot.
// Widths decide how many columns show (styles in app.css): three from 1200, the files pane as
// a fourth from 1440; from 760 the projects fold into a menu; below 760 one column at a time.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { actDoing, hostStateWords, type Store } from "../model/store";
import { agentsIn, counts, folderKey, headings, projectSubtitle, showsUnread } from "../model/groups";
import { parseQuery, queryMatches } from "../model/labels";
import type { Agent, ControlHost, ProjectSummary } from "../protocol/generated";
import { go, replace, route } from "../route";
import { setPane } from "./files/paneState";
import { browserName, type Session } from "../session";
import { Banner } from "./Banner";
import { Chat } from "./Chat";
import { NewAgent } from "./NewAgent";
import { CloningRows, EmptyProjects, NewProjectDialog, NewProjectItems, NewProjectMenu } from "./NewProject";
import { Problem } from "./Errors";
import { FilesPane } from "./FilesPane";
import { SessionRow } from "./SessionRow";
import { WorkflowRow } from "./WorkflowRow";
import { WorkflowPage } from "./WorkflowPage";
import { workflowSummary } from "../model/workflows";

export function Columns({ session, store }: { session: Session; store: Store }) {
  const r = route.value;
  const down = session.state.value.kind === "down";
  // Which single column a narrow window shows: the deepest one the route names.
  const depth = r.session || r.workflow || r.compose ? "chat" : r.project ? "sessions" : "projects";
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
      <Problem store={store} />
      <div class="columns" aria-busy={down}>
        <ProjectsColumn session={session} store={store} />
        <SessionsColumn store={store} linkDown={down} />
        {r.host && r.session ? <Chat store={store} host={r.host} session={r.session} down={down} />
          : r.host && r.project && project && r.workflow ? (
            <WorkflowPage store={store} host={r.host} folder={project.project.folder} projectName={project.name}
              workflowID={r.workflow} down={down || !store.hostIsOnline(r.host)} />
          ) : r.host && r.project && project ? (
            <NewAgent store={store} host={r.host} folder={project.project.folder} projectName={project.name} down={down} />
          ) : <section class="chat empty" aria-label="Chat"><p>Choose a project.</p></section>}
        {r.host && r.session && r.files && <FilesPane store={store} host={r.host} session={r.session} />}
      </div>
      <NewProjectDialog store={store} />
    </div>
  );
}

/** "This Mac" for the host on this Mac; otherwise its name, as the window heads them. */
function hostHeading(host: ControlHost): string {
  return host.id === "mac" ? "This Mac" : host.name;
}

function projectsOf(store: Store, host: ControlHost): ProjectSummary[] {
  return [...(store.projects.value[host.id] ?? [])].sort((a, b) => a.name.localeCompare(b.name));
}

/** How many of a project's sessions need the person, by the page's own grouping (FR-009). */
function needsYou(store: Store, host: string, folder: string): number {
  return counts(store.agents.value[host] ?? [], folder).needsAttention ?? 0;
}

function ProjectList({ store, onPick }: { store: Store; onPick?: () => void }) {
  const r = route.value;
  return (
    <>
      {store.hosts.value.map((host) => {
        const offline = host.state !== "online";
        return (
          <div class={`host${offline ? " host-offline" : ""}`} key={host.id}>
            <h2>{hostHeading(host)}</h2>
            {/* This Mac's host down is said whole, in the window's words (#83); a server's state as before. */}
            {offline && (host.id === "mac" ? (
              <div class="host-down" role="status">
                <p class="strong">⚠︎ This Mac’s host isn’t answering</p>
                <p class="quiet small">What’s listed is what it last said. The control plane is trying again by itself.</p>
              </div>
            ) : <p class="row offline">{hostStateWords(host.state)}: what's shown is from when it was last heard.</p>)}
            {projectsOf(store, host).map((project) => {
              const folder = project.project.folder;
              const chosen = r.host === host.id && r.project !== undefined && folderKey(r.project) === folderKey(folder);
              const needs = needsYou(store, host.id, folder);
              const subtitle = projectSubtitle(store.agents.value[host.id] ?? [], folder);
              return (
                <button key={folder} class={`row project${chosen ? " chosen" : ""}`} aria-current={chosen}
                  onClick={() => { go({ host: host.id, project: folder }); onPick?.(); }}>
                  <span class="title">{project.name}</span>
                  {subtitle && <span class="subtitle">{subtitle}</span>}
                  {needs > 0 && <span class="dot" aria-label="Needs you" />}
                </button>
              );
            })}
            <CloningRows store={store} host={host.id} />
          </div>
        );
      })}
    </>
  );
}

function ProjectsColumn({ session, store }: { session: Session; store: Store }) {
  const confirming = useSignal(false);
  return (
    <nav class="projects" aria-label="Projects">
      {/* New project at the head of the column, where the window's + sits over its sidebar (#115). */}
      <header class="column-head projects-head">
        <h1><span class="narrow-only">Agents</span></h1>
        <NewProjectMenu store={store} />
      </header>
      <div class="scroll"><ProjectList store={store} /><EmptyProjects store={store} /></div>
      <footer class="identity">
        <span>{browserName()} on this Mac</span>
        {confirming.value ? (
          <span class="confirm">
            <button onClick={() => void session.forgetThisBrowser()}>Forget</button>
            <button onClick={() => (confirming.value = false)}>Cancel</button>
          </span>
        ) : (
          <button class="link" onClick={() => (confirming.value = true)}>Forget This Browser…</button>
        )}
      </footer>
    </nav>
  );
}

/** Enough archived sessions to find last week's, as the window shows. */
const archivedShown = 50;

function SessionsColumn({ store, linkDown }: { store: Store; linkDown: boolean }) {
  const r = route.value;
  const down = linkDown || (r.host ? !store.hostIsOnline(r.host) : true);
  const menu = useSignal(false);
  const search = useSignal("");
  const showsArchived = useSignal(false);
  const host = r.host;
  const folder = r.project;
  useEffect(() => {
    showsArchived.value = false;
    if (host && folder) void store.loadWorkflows(host, folder);
  }, [host, folder]);
  const project = host && folder
    ? (store.projects.value[host] ?? []).find((p) => folderKey(p.project.folder) === folderKey(folder))
    : undefined;
  const agents: Agent[] = host ? store.agents.value[host] ?? [] : [];
  const query = parseQuery(search.value);
  const matching = (list: Agent[]) => (search.value.trim() ? list.filter((a) => queryMatches(query, a)) : list);
  const groups = folder ? headings(agents, folder).map((h) => ({ ...h, agents: matching(h.agents) }))
    .filter((h) => h.agents.length > 0) : [];
  const liveCount = groups.reduce((total, h) => total + h.agents.length, 0);
  const archived = folder ? matching(agentsIn(agents, folder, "archived")) : [];
  // A search narrows workflows by name and what they are; one asking for a label leaves them out
  // (SessionLabelQuery.matches(_: WorkflowSummary)).
  const runtimeName = (id: string) => (host ? store.runtimes.value[host] ?? [] : []).find((r) => r.runtime.id === id)?.runtime.name;
  const allWorkflows = (host && folder ? store.workflows.value[`${host}|${folderKey(folder)}`] ?? [] : [])
    .filter((w) => !search.value.trim() || query.label === null && (!query.text
      || [w.workflow.name, workflowSummary(w.workflow, runtimeName)].some((t) => t.toLowerCase().includes(query.text.toLowerCase()))))
    .sort((a, b) => a.workflow.name.localeCompare(b.workflow.name));
  const workflows = allWorkflows.filter((w) => !w.isArchived);
  const archivedWorkflows = allWorkflows.filter((w) => w.isArchived);
  const pick = (agent: Agent) => go({ host, project: folder, session: agent.id });
  const going = (agent: Agent) => {
    const act = store.onItsWay.value[agent.id];
    return act && typeof act === "string" && host ? { doing: actDoing(act), recipient: store.recipient(host) } : undefined;
  };
  const pickWorkflow = (id: string) => go({ host, project: folder, workflow: id });
  const openArchived = (open: boolean) => {
    showsArchived.value = open;
    if (open && host && folder) void store.loadArchived(host, folder);
  };
  return (
    // Greyed while its host is down, as the window's rows are (#83): what they show is what it last said.
    <section class={`sessions${r.host && !linkDown && !store.hostIsOnline(r.host) ? " greyed" : ""}`} aria-label="Sessions">
      <header class="column-head">
        <button class="back narrow-only" onClick={() => go({})}>‹ Projects</button>
        <span class="medium-only menu-anchor">
          <button class="project-menu" aria-haspopup="true" aria-expanded={menu.value} onClick={() => (menu.value = !menu.value)}>
            {project?.name ?? "Projects"} ▾
          </button>
          {menu.value && (
            <div class="popover" role="menu">
              <ProjectList store={store} onPick={() => (menu.value = false)} />
              <hr />
              <NewProjectItems store={store} onChoose={() => (menu.value = false)} />
            </div>
          )}
        </span>
        <h1 class="narrow-only">{project?.name ?? ""}</h1>
        <input class="search wide-only" type="search" placeholder="Search sessions and workflows"
          aria-label="Search sessions and workflows" value={search.value}
          onInput={(e) => {
            search.value = (e.currentTarget as HTMLInputElement).value;
            if (search.value) openArchived(true);
          }} />
        <button class="icon" aria-label="New session" title="Start a new session in this project" disabled={!project}
          onClick={() => go({ host, project: folder, compose: true })}>✎</button>
      </header>
      <div class="scroll">
        {!project && <p class="hint">Choose a project.</p>}
        {project && (
          <section class="group-list" aria-label="Sessions">
            <h2 class="section-head">Sessions <span class="count">{liveCount}</span></h2>
            {groups.map((group) => (
              <div class="group" key={group.group} role="group" aria-label={group.title}>
                <h3 class={`subhead${group.group === "needsAttention" ? " needs" : ""}`}>
                  {group.title} <span class="count">{group.agents.length}</span>
                  {group.agents.some(showsUnread) && <span> · {group.agents.filter(showsUnread).length} unread</span>}
                </h3>
                {group.agents.map((agent) => (
                  <SessionRow key={agent.id} agent={agent} chosen={r.session === agent.id} onPick={() => pick(agent)} going={going(agent)} />
                ))}
              </div>
            ))}
            {!search.value && liveCount === 0 && (
              <p class="hint">No sessions yet. Say what you want done on the right.</p>
            )}
            {search.value && liveCount === 0 && archived.length === 0 && workflows.length === 0 && (
              <p class="hint">No session or workflow matches “{search.value}”.</p>
            )}
            <details class="archived" open={showsArchived.value}
              onToggle={(e) => openArchived((e.currentTarget as HTMLDetailsElement).open)}>
              <summary class="subhead">Archived sessions{showsArchived.value && <span class="count"> {archived.length}</span>}</summary>
              {(search.value ? archived : archived.slice(0, archivedShown)).map((agent) => (
                <SessionRow key={agent.id} agent={agent} chosen={r.session === agent.id} onPick={() => pick(agent)} going={going(agent)} />
              ))}
              {showsArchived.value && project.retiredCount > 0 && !search.value && (
                <p class="hint">{project.retiredCount === 1 ? "1 older agent has been retired."
                  : `${project.retiredCount} older agents have been retired.`}</p>
              )}
            </details>
          </section>
        )}
        {project && (
          <section class="workflows" aria-label="Workflows">
            <h2 class="section-head">Workflows <span class="count">{workflows.length}</span></h2>
            {workflows.length === 0 && !search.value && <p class="hint">None</p>}
            {workflows.map((summary) => (
              <WorkflowRow key={summary.workflow.workflowID} store={store} host={host!} summary={summary} disabled={down}
                chosen={r.workflow === summary.workflow.workflowID} onPick={() => pickWorkflow(summary.workflow.workflowID)} />
            ))}
            {archivedWorkflows.length > 0 && (
              <details class="archived" open={!!search.value}>
                <summary class="subhead">Archived workflows <span class="count">{archivedWorkflows.length}</span></summary>
                {archivedWorkflows.map((summary) => (
                  <WorkflowRow key={summary.workflow.workflowID} store={store} host={host!} summary={summary} disabled={down}
                chosen={r.workflow === summary.workflow.workflowID} onPick={() => pickWorkflow(summary.workflow.workflowID)} />
                ))}
              </details>
            )}
          </section>
        )}
      </div>
    </section>
  );
}
