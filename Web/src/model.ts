// What the page shows, read over the link and kept up to date by notifications (071 US2).
// Phase 5 keeps it plain: hosts, their projects, each project's sessions newest first, and the
// open session's entries. The Mac window's grouping and reducer come in Phase 6 (T041–T047).
import { signal } from "@preact/signals";
import type { Agent, ControlHost, EntryNotification, ProjectSummary, TranscriptEntry } from "./protocol/generated";
import type { Link } from "./wire/link";

/** A folder URL without its trailing slash, so a project and its agents compare equal. */
export function folderKey(url: string): string {
  return url.replace(/\/+$/, "");
}

export class Model {
  readonly hosts = signal<ControlHost[]>([]);
  readonly projects = signal<Record<string, ProjectSummary[]>>({});
  readonly agents = signal<Record<string, Agent[]>>({});
  readonly entries = signal<TranscriptEntry[]>([]);
  private open: { host: string; session: string } | null = null;

  constructor(readonly link: Link) {
    link.onNotification((method, params, host) => this.heard(method, params, host));
    link.onState((state) => {
      if (state.kind === "open") void this.load();
    });
  }

  /** Everything again: on every connection, as the Mac window does (no cursors on the wire). */
  async load(): Promise<void> {
    const hosts = await this.link.call("hosts/list", {});
    this.hosts.value = hosts;
    const projects: Record<string, ProjectSummary[]> = {};
    const agents: Record<string, Agent[]> = {};
    await Promise.all(hosts.filter((host) => host.state === "online").map(async (host) => {
      const [p, a] = await Promise.all([
        this.link.call("projects/list", { includeArchived: false }, host.id).catch(() => []),
        this.link.call("agents/list", { includeArchived: false, archivedCommands: false, archivedOnly: false }, host.id)
          .catch(() => []),
      ]);
      projects[host.id] = p;
      agents[host.id] = a;
    }));
    this.projects.value = projects;
    this.agents.value = agents;
    if (this.open) await this.openSession(this.open.host, this.open.session);
  }

  sessions(host: string, folder: string): Agent[] {
    const key = folderKey(folder);
    return (this.agents.value[host] ?? [])
      .filter((agent) => folderKey(agent.cwd) === key)
      .sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  }

  agent(host: string, session: string): Agent | undefined {
    return (this.agents.value[host] ?? []).find((agent) => agent.id === session);
  }

  async openSession(host: string, session: string): Promise<void> {
    this.open = { host, session };
    this.entries.value = [];
    const page = await this.link.call("agents/transcript", { agentID: session as never, limit: 200 }, host).catch(() => null);
    if (page && this.open?.session === session) this.entries.value = page.entries;
  }

  closeSession(): void {
    this.open = null;
    this.entries.value = [];
  }

  private heard(method: string, params: unknown, host: string | null): void {
    if (method === "control/hostChanged") {
      void this.load();
      return;
    }
    if (!host) return;
    if (method === "agent/changed") {
      const agent = params as Agent;
      const list = (this.agents.value[host] ?? []).filter((a) => a.id !== agent.id);
      this.agents.value = { ...this.agents.value, [host]: [...list, agent] };
    } else if (method === "agent/removed") {
      const id = (params as { agentID?: string }).agentID;
      this.agents.value = { ...this.agents.value, [host]: (this.agents.value[host] ?? []).filter((a) => a.id !== id) };
    } else if (method === "project/changed") {
      const summary = params as ProjectSummary;
      const list = (this.projects.value[host] ?? []).filter((p) => folderKey(p.project.folder) !== folderKey(summary.project.folder));
      this.projects.value = { ...this.projects.value, [host]: [...list, summary] };
    } else if (method === "agent/entry") {
      const { agentID, entry } = params as EntryNotification;
      if (this.open?.host === host && this.open.session === agentID) {
        const kept = this.entries.value.filter((e) => e.id !== entry.id);
        this.entries.value = [...kept, entry];
      }
    }
  }
}
