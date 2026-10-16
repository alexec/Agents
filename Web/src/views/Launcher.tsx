// The launcher home (#1090), with Settings ▸ Sidebar ▸ Home window on Launcher: the page at #/ is
// cards in place of the sidebar, as the window's. Needs You across every project first, the pinned,
// one card per project with one grey line, the pages about all the work, and Settings. A project
// opens in this tab alone (#1089), with ‹ All back to the cards.
import type { Store } from "../model/store";
import type { Agent } from "../protocol/generated";
import { groupOf, projectFolder, showsUnread } from "../model/groups";
import { pinnedSessions } from "../model/sidebar";
import { launcherLine } from "../model/launcher";
import { alone, go, type ActivityPage } from "../route";
import { orderedProjects, projectLabel } from "./Sidebar";
import { NewProjectMenu } from "./NewProject";

const activity: { page: ActivityPage; title: string }[] = [
  { page: "events", title: "Events" }, { page: "resources", title: "Resources" },
  { page: "runtimes", title: "Runtimes" }, { page: "spending", title: "Cost" },
];

/** A project alone in this tab, at its new session or one of its sessions. */
export function openAlone(host: string, folder: string, session?: string): void {
  alone.value = { host, folder };
  go(session ? { host, project: folder, session } : { host, project: folder, compose: true });
}

export function Launcher({ store }: { store: Store }) {
  const projects = orderedProjects(store.hosts.value, store.projects.value);
  const live = (host: string, folder: string) => store.projectView(host, folder).headings.flatMap((h) => h.agents);
  const needing: { host: string; agent: Agent }[] = [];
  const pinned: { host: string; agent: Agent }[] = [];
  let approvals = 0;
  for (const { host, project } of projects) {
    const agents = live(host.id, project.project.folder);
    for (const agent of agents) {
      const group = groupOf(agent);
      if (group === "needsAttention" || group === "blocked") needing.push({ host: host.id, agent });
    }
    approvals += project.approvals?.length ?? 0;
    for (const agent of pinnedSessions(agents, store.sessionPinsIn(host.id, project.project.folder))) pinned.push({ host: host.id, agent });
  }
  const count = needing.length + approvals;
  const line = ({ host, agent }: { host: string; agent: Agent }) => (
    <li key={agent.id}>
      <button class="link session-line" title="Open in its project"
        onClick={() => openAlone(host, projectFolder(agent), agent.id)}>
        <span class="title">{agent.title ?? "Untitled"}</span>
        <span class="place">{decodeURIComponent(projectFolder(agent).replace(/\/+$/, "").split("/").pop() ?? "")}</span>
      </button>
    </li>
  );
  return (
    <section class="launcher" aria-label="Launcher">
      <header class="column-head"><h1>Agents</h1></header>
      <div class="scroll">
        <div class="cards">
          <div class={`card needs-you${count > 0 ? " needs" : ""}`} role="group" aria-label={`Needs You, ${count}`}>
            <h2>✋ Needs You · {count}</h2>
            {count === 0 && <p class="hint">Nothing is waiting for you</p>}
            <ul>{needing.slice(0, 6).map(line)}</ul>
            {needing.length > 6 && <p class="hint">and {needing.length - 6} more</p>}
          </div>
          {pinned.length > 0 && (
            <div class="card" role="group" aria-label="Pinned">
              <h2>Pinned</h2>
              <ul>{pinned.slice(0, 6).map(line)}</ul>
            </div>
          )}
          {projects.map(({ host, project }) => {
            const agents = live(host.id, project.project.folder);
            const working = agents.filter((a) => groupOf(a) === "running").length;
            const needs = agents.filter((a) => ["needsAttention", "blocked"].includes(groupOf(a))).length + (project.approvals?.length ?? 0);
            const unread = agents.filter(showsUnread).length;
            return (
              <button key={`${host.id}|${project.project.folder}`} class="card project-card"
                disabled={!store.hostIsOnline(host.id)} title={`Open ${project.name} on its own`}
                onClick={() => openAlone(host.id, project.project.folder)}>
                <h2>{projectLabel(host, project)}</h2>
                <p class="hint">{project.exists ? launcherLine(working, needs, unread) : "Folder is missing"}</p>
              </button>
            );
          })}
          <div class="card" role="group" aria-label="Activity">
            <h2>Activity</h2>
            <p>{activity.map(({ page, title }) => (
              <button key={page} class="link" onClick={() => go({ activity: page })}>{title}</button>
            ))}</p>
          </div>
          {/* Add Project…, as the sidebar's + has it (#115). */}
          <div class="card add-project" role="group" aria-label="Add Project">
            <NewProjectMenu store={store} />
          </div>
          <div class="card" role="group" aria-label="Settings">
            <button class="link" onClick={() => go({ settings: true })}>Settings</button>
          </div>
        </div>
      </div>
    </section>
  );
}
