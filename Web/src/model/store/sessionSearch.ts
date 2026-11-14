// Part of the Store (#5384): sessionSearch.
import { batch } from "@preact/signals";
import type { Agent, ListCursor, ListRequest, LineageSessionIssue } from "../../protocol/generated";
import { parseQuery } from "../labels";
import { folderKey, folderPath as agentFolderPath } from "../groups";
import { Capability } from "../../protocol/capabilities.generated";
import { isLead, leadEpic, leadProgressWords } from "../leadProgress";
import { sessionRef } from "../../protocol/ref";
import type { Store } from "../store";
import { archivedPage, searchShown } from "./shared";

export const sessionSearchMethods = {
  /**
   * A host's sessions (#4794): only what changed since the point held (the last catch-up's, or this
   * device's copy's), by `client/catchUp`; all of them when the host cannot say what changed since
   * then, and a page at a time from a host before `client/catchUp`.
   */
  async listSessions(this: Store, host: string): Promise<void> {
    const point = this.listPoint(host);
    const snapshot = !this.has(host, Capability.client1) ? null : await this.link.call("client/catchUp", {
      agents: { includeArchived: false, archivedCommands: false, archivedOnly: false, lean: true, ...(point ? { changedSince: point } : {}) },
      parts: [],
    }, host).catch(() => null);
    // A host before it, or one that does not answer it, lists as before, a page at a time.
    if (!snapshot) {
      const agents = await this.listLive(host);
      batch(() => {
        this.replaceAgents(agents, host);
        this.notePoint(undefined, host);
        this.answered(host);
      });
      return;
    }
    const changes = snapshot.agentChanges;
    if (point && changes && !changes.all) return this.takeChanges(snapshot.agents, changes, host);
    batch(() => {
      this.replaceAgents(snapshot.agents, host);
      this.notePoint(changes, host);
      this.answered(host);
    });
  },
  /**
   * Every live agent on a host, a page at a time: a host answers at most a page (#164).
   * Paged until one comes back short; a page longer than asked is a host from before pages.
   */
  async listLive(this: Store, host: string): Promise<Agent[]> {
    const limit = 500;
    const listed: Agent[] = [];
    const seen = new Set<string>();
    let after: ListCursor | undefined;
    for (let page = 0; page < 20; page++) {
      const got = await this.link.call("agents/list",
        { includeArchived: false, archivedCommands: false, archivedOnly: false, lean: true, limit, ...(after ? { after } : {}) }, host);
      for (const agent of got) if (!seen.has(agent.id)) { seen.add(agent.id); listed.push(agent); }
      const last = got[got.length - 1];
      if (got.length !== limit || !last) break;
      after = { lastActivityAt: last.lastActivityAt, id: last.id };
    }
    return listed;
  },
  /** The folder's workflow list is on screen. The first holder asks for it. */
  holdWorkflows(this: Store, host: string, folder: string): void {
    const key = `${host}|${folderKey(folder)}`;
    const count = this.workflowHolds.get(key) ?? 0;
    this.workflowHolds.set(key, count + 1);
    if (count === 0) void this.loadWorkflows(host, folder);
  },
  /** A view of the list went away. The last one lets the list go (#291). */
  releaseWorkflows(this: Store, host: string, folder: string): void {
    const key = `${host}|${folderKey(folder)}`;
    const left = (this.workflowHolds.get(key) ?? 1) - 1;
    if (left > 0) {
      this.workflowHolds.set(key, left);
      return;
    }
    this.workflowHolds.delete(key);
    this.workflowsLoaded.delete(key);
    this.writeWorkflows(key, undefined);
  },
  async loadWorkflows(this: Store, host: string, folder: string): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const listed = await this.link.call("workflows/list", { folder: folder as never }, host).catch(() => null);
    if (!this.workflowHolds.has(key)) return;
    this.workflowsLoaded.add(key);
    if (listed) this.writeWorkflows(key, listed);
  },
  /** One folder's newest `limit` archived sessions, asked for when a view of them opens (#170), such
   *  as the Archived Sessions page. Only more than is held is asked again. Each
   *  call is matched by one `unloadArchived` with the same limit. Whether the host answered (#664). */
  async loadArchived(this: Store, host: string, folder: string, limit = archivedPage): Promise<boolean> {
    const key = `${host}|${folderKey(folder)}`;
    const hold = this.archivedHolds.get(key) ?? { limits: [], listed: 0 };
    this.archivedHolds.set(key, hold);
    hold.limits.push(limit);
    if (limit <= hold.listed) return true;
    return this.listArchived(host, folder, key, limit);
  },
  async listArchived(this: Store, host: string, folder: string, key: string, limit: number, query?: string): Promise<boolean> {
    const hold = this.archivedHolds.get(key);
    if (hold && query === undefined) hold.listed = Math.max(hold.listed, limit);
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: false, archivedOnly: true, folder: folder as never, lean: true, limit,
      ...(query === undefined ? {} : { query }),
    }, host).catch(() => null);
    if (!listed) return false;
    if (this.archivedHolds.get(key) !== hold) return true;
    // On show in the fold now: no longer the search's to let go.
    for (const agent of listed) this.searched.get(host)?.delete(agent.id);
    this.addAgents(listed, host);
    return true;
  },
  /** The folder's archived sessions that match the words, from its host (#4451), as the Mac's
   *  searchArchived: an Archived Sessions page's filter finds one older than the page it holds. Held,
   *  and let go, with the page's own (`loadArchived`). Whether the host answered. */
  async searchArchived(this: Store, host: string, folder: string, words: string): Promise<boolean> {
    const key = `${host}|${folderKey(folder)}`;
    if (!this.archivedHolds.has(key)) return false;
    return this.listArchived(host, folder, key, searchShown, words);
  },
  /**
   * Ask every host for the sessions matching `words`, archived ones included, a capped page each
   * (#165, #193): the sidebar holds the live ones and filters those itself. What the last search
   * brought in is let go first, so the page holds one search's matches at a time.
   */
  async searchSessions(this: Store, words: string): Promise<void> {
    const turn = ++this.searchTurn;
    this.searchWords = words;
    this.searchNext.value = {};
    this.forgetSearched();
    this.saidLines.value = {};
    this.issueSessions.value = {};
    this.issueHeadings.value = [];
    if (!words) return;
    const issue = parseQuery(words).issue;
    const request: ListRequest = {
      includeArchived: true, archivedCommands: false, archivedOnly: false, lean: true, limit: searchShown, query: words,
    };
    for (const host of this.hosts.value) {
      if (turn !== this.searchTurn) return;
      if (!this.hostIsOnline(host.id)) continue;
      await this.search(request, host.id, turn);
      if (turn !== this.searchTurn) return;
      // The sessions on the issue, its sub-issues and their PRs (#3899). A host too old to say
      // matches the #<n> label only.
      if (issue !== null && this.has(host.id, Capability.lineageSessions1)) {
        const on = await this.link.call("lineage/sessions", { number: issue }, host.id).catch(() => null);
        if (Array.isArray(on?.matches) && turn === this.searchTurn) {
          this.issueSessions.value = { ...this.issueSessions.value, ...Object.fromEntries(on.matches.map((m) => [m.agentID, m.on])) };
          this.noteIssueHeadings(on.issues ?? []);
        }
        if (turn !== this.searchTurn) return;
      }
      // What was said (#1585): the sessions whose prompts or replies hold the words. Not asked of a
      // host too old to say (#1748).
      if (!this.has(host.id, Capability.agentsSaid1)) continue;
      const said = await this.link.call("agents/said", { text: words }, host.id).catch(() => null);
      if (Array.isArray(said?.matches) && turn === this.searchTurn) {
        this.saidLines.value = { ...this.saidLines.value, ...Object.fromEntries(said.matches.map((m) => [m.agentID, m.line])) };
      }
    }
  },
  noteIssueHeadings(this: Store, issues: readonly LineageSessionIssue[]): void {
    const held = [...this.issueHeadings.value];
    for (const issue of issues) {
      const at = held.findIndex((h) => h.node.kind === issue.node.kind && h.node.ref === issue.node.ref);
      if (at < 0) held.push(issue);
      else if (held[at]!.title === undefined && issue.title !== undefined) held[at] = { ...held[at]!, title: issue.title };
    }
    this.issueHeadings.value = held;
  },
  /** A lead's epic progress, asked of its host when its state or labels changed since; undefined for another session. */
  leadProgressOf(this: Store, host: string, agent: Agent): string | undefined {
    if (!isLead(agent) || agent.state === "archived") return undefined;
    const key = `${host}/${agent.id}`;
    const turn = `${agent.state}|${(agent.labels ?? []).map((l) => l.value).join(",")}`;
    if (this.leadAsked.get(key) !== turn && this.has(host, Capability.lineage1) && this.has(host, Capability.forge1)) {
      this.leadAsked.set(key, turn);
      void this.askLeadProgress(host, agent.id, key);
    }
    return this.leadProgress.value[key];
  },
  async askLeadProgress(this: Store, host: string, id: string, key: string): Promise<void> {
    // A call that fails keeps what the row said: the next wake asks again.
    const walked = await this.link.call("lineage/walk", { node: { kind: "session", ref: sessionRef(id) }, depth: 1 }, host).catch(() => null);
    if (!walked) return;
    const epic = leadEpic(id, walked.links);
    const plan = epic ? await this.link.call("forge/plan", { node: epic }, host).catch(() => null) : undefined;
    if (plan === null) return;
    const words = plan ? leadProgressWords(plan) : undefined;
    const { [key]: _, ...rest } = this.leadProgress.value;
    this.leadProgress.value = words ? { ...rest, [key]: words } : rest;
  },
  /** The next page from each host that has more, newest first as the host lists them. */
  async searchMore(this: Store): Promise<void> {
    const turn = this.searchTurn;
    const next = this.searchNext.value;
    this.searchNext.value = {};
    for (const [host, request] of Object.entries(next)) {
      if (turn !== this.searchTurn) return;
      await this.search(request, host, turn);
    }
  },
  async search(this: Store, request: ListRequest, host: string, turn: number): Promise<void> {
    const found = await this.link.call("agents/list", request, host).catch(() => null);
    // The search ended or changed while this was on its way: not what is asked now.
    if (!found || turn !== this.searchTurn) return;
    const archived = found.filter((a) => a.state === "archived");
    const held = new Set((this.agents.value[host] ?? []).map((a) => a.id));
    const brought = this.searched.get(host) ?? new Set<string>();
    for (const agent of archived) if (!held.has(agent.id)) brought.add(agent.id);
    this.searched.set(host, brought);
    if (archived.length) this.addAgents(archived, host);
    const last = found[found.length - 1];
    if (found.length === request.limit && last) {
      this.searchNext.value = { ...this.searchNext.value,
        [host]: { ...request, after: { lastActivityAt: last.lastActivityAt, id: last.id } } };
    }
  },
  /** What searches brought in, let go: the open session stays, and anything no longer archived. */
  forgetSearched(this: Store): void {
    const watching = this.watching.value;
    for (const [host, ids] of this.searched) {
      const held = this.agents.value[host] ?? [];
      const gone = held.filter((a) => ids.has(a.id) && a.state === "archived"
        && !(watching?.host === host && watching.session === a.id));
      if (gone.length) {
        const without = new Set(gone.map((a) => a.id));
        this.setAgents(host, held.filter((a) => !without.has(a.id)), [...new Set(gone.map(agentFolderPath))]);
      }
    }
    this.searched.clear();
  },
  /** A view of them closed: once the last has, the folder's archived sessions are let go, and listed
   *  again when one opens. */
  unloadArchived(this: Store, host: string, folder: string, limit = archivedPage): void {
    const key = `${host}|${folderKey(folder)}`;
    const hold = this.archivedHolds.get(key);
    if (hold) {
      const at = hold.limits.indexOf(limit);
      if (at >= 0) hold.limits.splice(at, 1);
      if (hold.limits.length > 0) return;
    }
    this.archivedHolds.delete(key);
    this.dropArchived(host, folder);
  },
};
