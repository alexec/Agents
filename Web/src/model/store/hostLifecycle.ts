// Part of the Store (#5384): hostLifecycle.
import { preferencesSaid } from "../preferences";
import { batch } from "@preact/signals";
import type { MachineRef, MachineWorkspace } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { log } from "../../log";
import { folderKey } from "../groups";
import { hostAnswers } from "../capabilities";
import { Capability } from "../../protocol/capabilities.generated";
import { markOnce } from "../marks";
import type { Store } from "../store";
import { pruneFolderKeys, searchShown, byAsked } from "./shared";

export const hostLifecycleMethods = {
  onHost(this: Store, host: string, work: () => Promise<void>): Promise<void> {
    const prev = this.hostChain.get(host) ?? Promise.resolve();
    const run = prev.then(work, work);
    const done = run.finally(() => {
      if (this.hostChain.get(host) === done) this.hostChain.delete(host);
    });
    this.hostChain.set(host, done);
    return run;
  },
  /** Runs `work` for `key` unless it is running already; then once more when it ends, however often asked. */
  once(this: Store, key: string, work: () => Promise<void>): Promise<void> {
    const now = this.running.get(key);
    if (now) {
      now.again = true;
      return now.done;
    }
    const entry = { done: Promise.resolve(), again: false };
    entry.done = (async () => {
      try {
        do {
          entry.again = false;
          await work().catch(() => {});
        } while (entry.again);
      } finally {
        this.running.delete(key);
      }
    })();
    this.running.set(key, entry);
    return entry.done;
  },
  /**
   * One host came, went or changed (`control/hostChanged`): the hosts are listed again, and that
   * host's data alone loaded once it is online, a quarter of a second after the last word about
   * it (the control plane says it twice per connect). A control plane naming no host loads all (#170).
   */
  hostChanged(this: Store, params: unknown): void {
    const said = params as { host?: unknown; state?: unknown; workspace?: MachineWorkspace } | null;
    const host = said?.host;
    if (typeof host !== "string") {
      void this.load();
      return;
    }
    // Its state and workspace as said, at once: a workspace's start shows its steps as they come (#691).
    if (typeof said?.state === "string" && said.state !== "removed") this.takeHostRow({ id: host, state: said.state, workspace: said.workspace });
    clearTimeout(this.settling.get(host));
    this.settling.set(host, setTimeout(() => {
      this.settling.delete(host);
      void this.once(host, () => this.reloadHost(host));
    }, 250));
  },
  async reloadHost(this: Store, host: string): Promise<void> {
    const hosts = await this.link.call("machines/list", {});
    this.takeHosts(hosts);
    await this.onHost(host, async () => {
      const now = this.hosts.value.find((h) => h.id === host);
      if (!now) return this.forgetHost(host);
      if (!hostAnswers(now.state)) return this.loadLastHeard(host);
      await this.loadHost(host);
      const watching = this.watching.value;
      if (watching?.host === host) await this.loadTranscript(host, watching.session);
    });
  },
  /** A host removed: what was held of it goes with it, the runtimes included (#291). */
  forgetHost(this: Store, host: string): void {
    const prefix = `${host}|`;
    this.listPoints.delete(host);
    pruneFolderKeys(host, []);
    const without = <T,>(held: Record<string, T>) => Object.fromEntries(Object.entries(held).filter(([key]) => key !== host));
    const notOf = <T,>(held: Record<string, T>) => Object.fromEntries(Object.entries(held).filter(([key]) => !key.startsWith(prefix)));
    this.dropHostRecords(host);
    for (const key of [...this.startRequests.keys()]) if (key.startsWith(prefix)) this.startRequests.delete(key);
    batch(() => {
      this.setAgents(host, []);
      this.agents.value = without(this.agents.value);
      this.folders.value = without(this.folders.value);
      this.clones.value = without(this.clones.value);
      this.permissions.value = without(this.permissions.value);
      this.elicitations.value = without(this.elicitations.value);
      this.workflows.value = notOf(this.workflows.value);
      this.pageRevisions.value = notOf(this.pageRevisions.value);
      this.pins.value = notOf(this.pins.value);
      this.sessionPins.value = notOf(this.sessionPins.value);
      this.workflowPins.value = notOf(this.workflowPins.value);
      this.serverViews.value = notOf(this.serverViews.value);
      this.reviewPulls.value = notOf(this.reviewPulls.value);
      this.checkSuggestions.value = notOf(this.checkSuggestions.value);
      this.leases.value = without(this.leases.value);
      this.hostedMCP.value = without(this.hostedMCP.value);
      this.mcpHealth.value = without(this.mcpHealth.value);
      this.endedConnections.value = without(this.endedConnections.value);
      this.endedInFolders.value = notOf(this.endedInFolders.value);
      this.runtimes.value = without(this.runtimes.value);
      this.accounts.value = without(this.accounts.value);
      this.sandboxDefaults.value = without(this.sandboxDefaults.value);
      this.sandboxSetBy.value = without(this.sandboxSetBy.value);
      this.policyStates.value = without(this.policyStates.value);
      this.passThrough.value = without(this.passThrough.value);
      this.rememberedModes.value = without(this.rememberedModes.value);
      this.resuming.value = without(this.resuming.value);
      this.events.value = without(this.events.value);
      this.costs.value = without(this.costs.value);
      this.usageReadAt.value = without(this.usageReadAt.value);
      this.disk.value = without(this.disk.value);
      this.storeNotes.value = without(this.storeNotes.value);
    });
    for (const key of [...this.archivedHolds.keys()]) if (key.startsWith(prefix)) this.archivedHolds.delete(key);
    this.searched.delete(host);
    if (this.searchNext.value[host]) this.searchNext.value = without(this.searchNext.value);
  },
  /** What an offline host last listed, from the control plane (#962), when nothing of it is held:
   *  a page opened while it is stopped lists its folders and sessions as one open when it went. */
  async loadLastHeard(this: Store, host: string): Promise<void> {
    // What this device's copy drew is not held: the control plane's word is newer (#4790).
    const held = () => this.folders.value[host] !== undefined && !this.fromDevice.value.has(host);
    if (this.hostIsOnline(host) || held()) return;
    const heard = await this.link.call("machines/lastHeard", { host: host as MachineRef }).catch(() => null);
    if (!heard || this.hostIsOnline(host) || held()) return;
    batch(() => {
      this.answered(host);
      if (heard.agents) this.replaceAgents(heard.agents, host);
      if (heard.folders) this.folders.value = { ...this.folders.value, [host]: this.hidingAnsweredIn(heard.folders, host) };
    });
  },
  async loadHost(this: Store, host: string): Promise<void> {
    // Logged by code alone: a host's words never reach the console (FR-033).
    const failed = (_what: string) => (error: unknown) => {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      return null;
    };
    // Lean: the columns read none of the option and command lists, 4 MB of 200 agents (#107).
    // The open session's come with loadWhole.
    if (await this.listSessions(host).then(() => true, failed("client/catchUp"))) markOnce("first-list", "connected");
    // The Archived folds that were open are listed again rather than left empty by the live list,
    // and the workflows on screen asked again: they may have changed meanwhile.
    const prefix = `${host}|`;
    for (const [key, hold] of this.archivedHolds) {
      if (!key.startsWith(prefix)) continue;
      hold.listed = 0;
      void this.listArchived(host, key.slice(prefix.length), key, Math.max(...hold.limits));
    }
    // Only what is on screen: a list left behind is not asked for again (#291).
    for (const key of this.workflowHolds.keys()) if (key.startsWith(prefix)) void this.loadWorkflows(host, key.slice(prefix.length));
    // A search on show: the live list just let its archived matches go, so they are asked again.
    if (this.searchWords) {
      this.searched.delete(host);
      const { [host]: _again, ...rest } = this.searchNext.value;
      this.searchNext.value = rest;
      void this.search({ includeArchived: true, archivedCommands: false, archivedOnly: false, lean: true,
        limit: searchShown, query: this.searchWords }, host, this.searchTurn);
    }
    // Archived ones too, as the window lists them: the sidebar folds them under Archived folders
    // (#343), and Spending still counts what they cost.
    const folders = await this.link.call("folders/list", { includeArchived: true }, host).catch(failed("folders/list"));
    if (folders) {
      this.folders.value = { ...this.folders.value, [host]: this.hidingAnsweredIn(folders, host) };
      pruneFolderKeys(host, folders.map((p) => p.folder.folder));
    }
    const clones = await this.link.call("folders/clones", {}, host).catch(failed("folders/clones"));
    if (clones) this.clones.value = { ...this.clones.value, [host]: clones };
    if (this.has(host, Capability.sessionsMoving1)) {
      void this.link.call("agents/moves", {}, host).then((moving) => {
        if (moving.length > 0) this.moves.value = { ...this.moves.value, ...Object.fromEntries(moving.map((m) => [m.agentID, m])) };
      }).catch(failed("agents/moves"));
    }
    void this.loadRuntimes(host);
    void this.link.call("pins/list", {}, host).then((listed) => {
      const held = Object.fromEntries(Object.entries(this.pins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const sessions = Object.fromEntries(Object.entries(this.sessionPins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const flows = Object.fromEntries(Object.entries(this.workflowPins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const views = Object.fromEntries(Object.entries(this.serverViews.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const reviews = Object.fromEntries(Object.entries(this.reviewPulls.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const suggestions = Object.fromEntries(Object.entries(this.checkSuggestions.value).filter(([key]) => !key.startsWith(`${host}|`)));
      for (const folder of listed) {
        views[`${host}|${folderKey(folder.folder)}`] = folder.views ?? [];
        reviews[`${host}|${folderKey(folder.folder)}`] = folder.reviews ?? [];
        suggestions[`${host}|${folderKey(folder.folder)}`] = folder.suggestions ?? [];
        held[`${host}|${folderKey(folder.folder)}`] = folder.pins;
        sessions[`${host}|${folderKey(folder.folder)}`] = folder.sessions ?? [];
        flows[`${host}|${folderKey(folder.folder)}`] = folder.workflows ?? [];
      }
      this.pins.value = held;
      this.sessionPins.value = sessions;
      this.workflowPins.value = flows;
      this.serverViews.value = views;
      this.reviewPulls.value = reviews;
      this.checkSuggestions.value = suggestions;
    }).catch(failed("pins/list"));
    // A host from before #3863 has none.
    void this.link.call("requests/list", {}, host).then(({ requests }) => {
      this.personRequests.value = { ...this.personRequests.value, [host]: requests.filter((r) => r.state === "open").sort(byAsked) };
    }).catch(() => {});
    // A host from before #251 doesn't answer, and nothing is said to be coming back.
    void this.link.call("agents/resuming", {}, host).then((response) => {
      this.resuming.value = { ...this.resuming.value, [host]: response.agentIDs };
    }).catch(failed("agents/resuming"));
    void this.link.call("resources/snapshot", {}, host).then((snapshot) => {
      this.leases.value = { ...this.leases.value, [host]: snapshot };
    }).catch(failed("resources/snapshot"));
    // A host from before #488 doesn't know the method, and hosts no servers.
    void this.link.call("mcp/hosted", {}, host).then((snapshot) => {
      this.hostedMCP.value = { ...this.hostedMCP.value, [host]: snapshot };
    }).catch(failed("mcp/hosted"));
    // A host from before #753 doesn't know it: its page shows the hosted servers alone.
    void this.link.call("mcp/health", {}, host).then((snapshot) => {
      this.mcpHealth.value = { ...this.mcpHealth.value, [host]: snapshot };
    }).catch(failed("mcp/health"));
    void this.loadConnections(host);
    // A host too old to know disk/state says nothing, and no strip is drawn.
    void this.link.call("disk/state", {}, host).then((state) => {
      this.disk.value = { ...this.disk.value, [host]: state };
    }).catch(failed("disk/state"));
    // A host from before #4748 doesn't know it: its row says nothing of its capacity.
    void this.link.call("capacity/state", {}, host).then((state) => {
      this.capacity.value = { ...this.capacity.value, [host]: state };
    }).catch(failed("capacity/state"));
    // A host too old to know store/notes says nothing, as one with nothing to say.
    void this.link.call("store/notes", {}, host).then((state) => {
      this.storeNotes.value = { ...this.storeNotes.value, [host]: state.notes };
    }).catch(failed("store/notes"));
    // The person's display choices, from their Mac (#1033). A Mac too old to know the method
    // leaves every choice at its default.
    if (host === this.macHostID.peek()) {
      void this.link.call("preferences/get", {}, host).then((said) => preferencesSaid(said))
        .catch(failed("preferences/get"));
      // The Summary row (#3721): shown only while the daily summary is on, with its newest page.
      void this.link.call("dailySummary/settings", {}, host).then((settings) => { this.dailySummary.value = settings; })
        .catch(failed("dailySummary/settings"));
      void this.link.call("summaries/list", {}, host).then((pages) => { this.summaryPages.value = pages; })
        .catch(failed("summaries/list"));
    }
    // A host from before #984 doesn't know it: the Time page shows no achievements.
    void this.link.call("achievements/state", {}, host).then((state) => this.takeAchievements(host, state))
      .catch(failed("achievements/state"));
    // A host from before #3903 doesn't know it: the Multiplier page shows — ×.
    void this.link.call("multiplier/state", {}, host)
      .then((state) => { this.multiplier.value = { ...this.multiplier.value, [host]: state }; this.usageRead(host, "multiplier"); })
      .catch(failed("multiplier/state"));
    const [permissions, elicitations] = await Promise.all([
      this.link.call("permissions/pending", {}, host).catch(failed("permissions/pending")),
      this.link.call("elicitations/pending", {}, host).catch(failed("elicitations/pending")),
    ]);
    batch(() => {
      if (permissions) this.permissions.value = { ...this.permissions.value,
        [host]: [...permissions].sort((a, b) => a.askedAt - b.askedAt) };
      if (elicitations) this.elicitations.value = { ...this.elicitations.value, [host]: elicitations };
    });
  },
};
