// The Mac window's layout in a tab (071 US2, US6; frames A–D): projects under host headings,
// the chosen project's sessions, and the chosen session's chat with the prompt at its foot.
// Widths decide how many columns show (styles in app.css): three from 1200, the files pane as
// a fourth from 1440; from 760 the projects fold into a menu; below 760 one column at a time.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Model } from "../model";
import { folderKey } from "../model";
import type { Agent, ControlHost, ProjectSummary } from "../protocol/generated";
import { go, route } from "../route";
import { browserName, type Session } from "../session";
import { Banner } from "./Banner";
import { Chat } from "./Chat";
import { FilesPane } from "./FilesPane";

export function Columns({ session, model }: { session: Session; model: Model }) {
  const r = route.value;
  const down = session.state.value.kind === "down";
  // Which single column a narrow window shows: the deepest one the route names.
  const depth = r.session ? "chat" : r.project ? "sessions" : "projects";
  useEffect(() => {
    if (r.host && r.session) void model.openSession(r.host, r.session);
    else model.closeSession();
  }, [r.host, r.session]);
  return (
    <div class={`app depth-${depth}${r.files && r.session ? " files-open" : ""}${down ? " down" : ""}`}>
      {down && <Banner session={session} />}
      <div class="columns" aria-busy={down}>
        <ProjectsColumn session={session} model={model} />
        <SessionsColumn session={session} model={model} />
        {r.host && r.session ? <Chat model={model} host={r.host} session={r.session} down={down} />
          : <section class="chat empty" aria-label="Chat"><p>Choose a session.</p></section>}
        {r.host && r.session && r.files && <FilesPane model={model} host={r.host} session={r.session} />}
      </div>
    </div>
  );
}

/** "This Mac" for the host on this Mac; otherwise its name, as the window heads them. */
function hostHeading(host: ControlHost): string {
  return host.id === "mac" ? "This Mac" : host.name;
}

function projectsOf(model: Model, host: ControlHost): ProjectSummary[] {
  return [...(model.projects.value[host.id] ?? [])].sort((a, b) => a.name.localeCompare(b.name));
}

function ProjectList({ model, onPick }: { model: Model; onPick?: () => void }) {
  const r = route.value;
  return (
    <>
      {model.hosts.value.map((host) => {
        const offline = host.state !== "online";
        return (
          <div class="host" key={host.id}>
            <h2>{hostHeading(host)}</h2>
            {offline && <p class="row offline">{host.state === "offline" ? "Offline" : host.state}</p>}
            {projectsOf(model, host).map((project) => {
              const folder = project.project.folder;
              const chosen = r.host === host.id && r.project !== undefined && folderKey(r.project) === folderKey(folder);
              const needs = project.counts.needsAttention ?? 0;
              return (
                <button key={folder} class={`row project${chosen ? " chosen" : ""}`} aria-current={chosen}
                  onClick={() => { go({ host: host.id, project: folder }); onPick?.(); }}>
                  <span class="title">{project.name}</span>
                  {needs > 0 && <span class="subtitle">{needs === 1 ? "Needs you" : `${needs} need you`}</span>}
                  {needs > 0 && <span class="dot" aria-label="Needs you" />}
                </button>
              );
            })}
          </div>
        );
      })}
    </>
  );
}

function ProjectsColumn({ session, model }: { session: Session; model: Model }) {
  const confirming = useSignal(false);
  const state = session.state.value;
  const grant = state.kind === "open" && state.grant === "operator" ? "Operator" : "Device";
  return (
    <nav class="projects" aria-label="Projects">
      <header class="column-head narrow-only"><h1>Agents</h1></header>
      <div class="scroll"><ProjectList model={model} /></div>
      <footer class="identity">
        <span>{browserName()} on this Mac · {grant}</span>
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

function SessionsColumn({ model }: { session: Session; model: Model }) {
  const r = route.value;
  const menu = useSignal(false);
  const search = useSignal("");
  const project = r.host && r.project
    ? (model.projects.value[r.host] ?? []).find((p) => folderKey(p.project.folder) === folderKey(r.project!))
    : undefined;
  const sessions: Agent[] = r.host && r.project ? model.sessions(r.host, r.project) : [];
  const shown = search.value
    ? sessions.filter((a) => (a.title ?? "").toLowerCase().includes(search.value.toLowerCase()))
    : sessions;
  return (
    <section class="sessions" aria-label="Sessions">
      <header class="column-head">
        <button class="back narrow-only" onClick={() => go({})}>‹ Projects</button>
        <span class="medium-only menu-anchor">
          <button class="project-menu" aria-haspopup="true" aria-expanded={menu.value} onClick={() => (menu.value = !menu.value)}>
            {project?.name ?? "Projects"} ▾
          </button>
          {menu.value && (
            <div class="popover" role="menu">
              <ProjectList model={model} onPick={() => (menu.value = false)} />
            </div>
          )}
        </span>
        <h1 class="narrow-only">{project?.name ?? ""}</h1>
        <input class="search wide-only" type="search" placeholder="Search sessions" aria-label="Search sessions"
          value={search.value} onInput={(e) => (search.value = (e.currentTarget as HTMLInputElement).value)} />
        <button class="icon" aria-label="New session" title="New session" disabled>✎</button>
      </header>
      <div class="scroll">
        {!project && <p class="hint">Choose a project.</p>}
        {project && shown.length === 0 && <p class="hint">No sessions yet.</p>}
        {shown.map((agent) => {
          const chosen = r.session === agent.id;
          return (
            <button key={agent.id} class={`row session${chosen ? " chosen" : ""}`} aria-current={chosen}
              onClick={() => go({ host: r.host, project: r.project, session: agent.id })}>
              <span class="title">{agent.title ?? "New session"}</span>
              <span class="subtitle">{stateWords(agent)}</span>
            </button>
          );
        })}
      </div>
    </section>
  );
}

/** Plain words for now; the Mac window's groups and status words come in Phase 6 (T043). */
function stateWords(agent: Agent): string {
  switch (agent.state) {
    case "running": return "Working";
    case "waitingOnUser": return "Needs you";
    case "finished": return "Done";
    case "stopped": return "Stopped";
    case "archived": return "Archived";
    default: return "Starting";
  }
}
