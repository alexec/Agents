// Part of the Store (#5384): agentSettings.
import type { WorkflowSummary, JSONValue, StartRequest, UUID, WorktreesListResponse, Persona, ConfigOption, WorkflowSettings, WorkflowHours, FileMentionDTO, KeptRequest, BuildOutputRemoved, RemovalCheck, WorktreeSize, WorktreeSummary } from "../../protocol/generated";
import { Failure } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { describe, methodNotFound } from "../errors";
import { log } from "../../log";
import { folderKey } from "../groups";
import type { WhenDone } from "../workflowSettings";
import { type AgentWrite } from "../pendingWrites";
import { labelsUndo, mutedUndo, renamedUndo } from "../changeUndo";
import type { Store } from "../store";
import { type SandboxWillNotStart, isSandboxRefusal } from "./shared";

export const agentSettingsMethods = {
  /**
   * One setting, its label list, its cooldown, the computers it runs on or what a run may do
   * when done (#162, #317, #433), written
   * to the file through the daemon as the window's page writes it. `change` is applied to what
   * the file says when the call is sent, after any earlier change to the same workflow has been
   * answered, so two quick changes cannot undo each other. The answer replaces the one summary;
   * the list is not asked for again. Answers the daemon's refusal, for the page to say beside
   * the controls, or null.
   */
  setWorkflowSettings(this: Store, host: string, summary: WorkflowSummary,
                      change: { settings?: (s: WorkflowSettings) => WorkflowSettings; cooldown?: string; hours?: WorkflowHours; labels?: (labels: string[]) => string[]; runsOn?: string[]; whenDone?: WhenDone; continueWhenBack?: boolean }): Promise<string | null> {
    const { folder, workflowID } = summary.workflow;
    const key = `${host}|${folderKey(folder)}|${workflowID}`;
    const send = async (): Promise<string | null> => {
      const latest = (this.workflows.value[`${host}|${folderKey(folder)}`] ?? []).find((w) => w.workflow.workflowID === workflowID) ?? summary;
      const current = latest.workflow.settings;
      const settings = change.settings ? change.settings(current) : current;
      try {
        const updated = await this.link.call("workflows/settings", {
          folder, workflowID, settings,
          ...(change.cooldown !== undefined ? { cooldown: change.cooldown } : {}),
          ...(change.hours !== undefined ? { hours: change.hours } : {}),
          ...(change.labels !== undefined ? { labels: change.labels(current.labels) } : {}),
          ...(change.runsOn !== undefined ? { runsOn: change.runsOn } : {}),
          ...(change.whenDone !== undefined ? { whenDone: change.whenDone } : {}),
          ...(change.continueWhenBack !== undefined ? { continueWhenBack: change.continueWhenBack } : {}),
        }, host);
        this.placeWorkflow(updated, host);
        return null;
      } catch (error) {
        log("call.failed", error instanceof CallFailed ? error.code : undefined);
        return describe(error);
      }
    };
    const next = (this.settingsInFlight.get(key) ?? Promise.resolve()).then(send);
    this.settingsInFlight.set(key, next);
    void next.finally(() => { if (this.settingsInFlight.get(key) === next) this.settingsInFlight.delete(key); });
    return next;
  },
  /** What a runtime last advertised in a folder, for the workflow page's menus; starts nothing. */
  async rememberedOptions(this: Store, host: string, runtimeID: string, folder: string): Promise<ConfigOption[]> {
    return (await this.link.call("options/remembered", { runtimeID, cwd: folder as never }, host).catch(() => null)) ?? [];
  },
  /**
   * Ask a session's host to start its runtime ahead of a prompt (#183): it was opened, or
   * somebody is typing in it. Once per session and reason in a while, however many keys;
   * the host debounces too. Silent: an older host that does not know the call is not warmed.
   */
  prewarm(this: Store, host: string, agentID: string, why: "opened" | "typing"): void {
    const agent = this.agent(host, agentID);
    if (!agent || (agent.state !== "finished" && agent.state !== "stopped")) return;
    const key = `${host}|${agentID}|${why}`;
    const now = Date.now();
    if (now - (this.prewarmed.get(key) ?? 0) < 15_000) return;
    this.prewarmed.set(key, now);
    if (this.prewarmed.size > 64) {
      for (const [k, at] of this.prewarmed) if (now - at >= 15_000) this.prewarmed.delete(k);
    }
    void this.link.call("agents/prewarm", { agentID: agentID as UUID, why }, host).catch(() => {});
  },
  /** The person's title for a session (#751); empty, the runtime names it again. */
  async rename(this: Store, host: string, agentID: string, title: string, offeringUndo = true): Promise<void> {
    const write: AgentWrite = { kind: "rename", title };
    const before = offeringUndo ? this.agent(host, agentID) : undefined;
    const done = await this.optimistic(host, agentID, write, async () =>
      await this.act("agents/rename", { agentID: agentID as UUID, title }, host, write) !== null);
    if (done && before) this.offerUndo(host, renamedUndo(before, title));
  },
  /** Mute Notifications / Unmute Notifications (#2003): kept by the session's host. */
  async setMuted(this: Store, host: string, agentID: string, muted: boolean, offeringUndo = true): Promise<void> {
    const write: AgentWrite = { kind: "mute", muted };
    const before = offeringUndo ? this.agent(host, agentID) : undefined;
    const done = await this.optimistic(host, agentID, write, async () =>
      await this.act("agents/setMuted", { agentID: agentID as UUID, muted }, host, write) !== null);
    if (done && before) this.offerUndo(host, mutedUndo(before, muted));
  },
  /** Mute Notifications for a workflow's runs, or Unmute (#2003): `muted: true` in its file. */
  async setWorkflowMuted(this: Store, host: string, summary: WorkflowSummary, muted: boolean): Promise<void> {
    const changed = await this.act("workflows/setMuted",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, muted }, host);
    if (changed) this.placeWorkflow(changed, host);
  },
  /** Mark as Unread / Mark as Read (#70). */
  async setUnread(this: Store, host: string, agentID: string, unread: boolean): Promise<void> {
    await this.act("agents/setUnread", { agentID: agentID as UUID, unread }, host);
  },
  /** A menu's choice, shown at once and sent; the host's answer settles it either way. */
  async setOption(this: Store, host: string, agentID: string, optionID: string, value: JSONValue): Promise<void> {
    this.pendingOptions.value = { ...this.pendingOptions.value,
      [agentID]: { ...this.pendingOptions.value[agentID], [optionID]: value } };
    await this.act("agents/setOption", { agentID: agentID as UUID, optionID, value }, host);
    const mine = { ...this.pendingOptions.value[agentID] };
    if (JSON.stringify(mine[optionID]) === JSON.stringify(value)) delete mine[optionID];
    this.pendingOptions.value = { ...this.pendingOptions.value, [agentID]: mine };
  },
  async setLabels(this: Store, host: string, agentID: string, add: string[], remove: string[], offeringUndo = true): Promise<boolean> {
    const write: AgentWrite = { kind: "labels", add, remove };
    const before = offeringUndo ? this.agent(host, agentID) : undefined;
    const done = await this.optimistic(host, agentID, write, async () => {
      const agent = await this.act("agents/setLabels", { agentID: agentID as UUID, add, remove }, host, write);
      if (agent) this.upsertAgent(agent, host);
      return agent !== null;
    });
    if (done && before) this.offerUndo(host, labelsUndo(before, add, remove));
    return done;
  },
  async labelVocabulary(this: Store, host: string, folder: string): Promise<string[]> {
    return (await this.link.call("agents/labelVocabulary", { folder: folder as never }, host).catch(() => null)) ?? [];
  },
  /** The personas a start in this folder can pick (#760); none from a host too old to know them,
   *  and null when the host did not answer, so the page asks again once it does (#1096). */
  async personas(this: Store, host: string, folder: string): Promise<Persona[] | null> {
    return this.link.call("personas/list", { folder: folder as never }, host)
      .catch((error: unknown) => (error instanceof CallFailed && error.code === methodNotFound ? [] : null));
  },
  async worktrees(this: Store, host: string, folder: string): Promise<WorktreesListResponse | null> {
    return this.link.call("worktrees/list", { folder: folder as never }, host).catch(() => null);
  },
  /** A worktree's size, the newest heard (#790): from `worktrees/sized`, else its list's. */
  worktreeSize(this: Store, host: string, worktree: WorktreeSummary): WorktreeSize | undefined {
    return this.worktreeSizes.value[host]?.[worktree.root] ?? worktree.size;
  },
  /** Every folder's worktrees on a host, for Activity ▸ Worktrees (#790). */
  async loadWorktrees(this: Store, host: string): Promise<void> {
    const listed = await this.link.call("worktrees/all", {}, host).catch(() => null);
    if (!listed) return;
    this.worktreeLists.value = { ...this.worktreeLists.value, [host]: listed };
    // What the list now says is as new as anything heard before it.
    const { [host]: _, ...rest } = this.worktreeSizes.value;
    this.worktreeSizes.value = rest;
  },
  /** What removing a worktree would lose; null when it could not be asked, and the problem says why. */
  async checkWorktreeRemoval(this: Store, host: string, folder: string, root: string): Promise<RemovalCheck | null> {
    return this.link.call("worktrees/check", { folder: folder as never, root: root as never, confirmed: false }, host)
      .catch((error: unknown) => { this.say(describe(error)); return null; });
  },
  /** Remove a worktree; the host checks again either way. */
  async removeWorktree(this: Store, host: string, folder: string, root: string, confirmed: boolean): Promise<void> {
    await this.link.call("worktrees/remove", { folder: folder as never, root: root as never, confirmed }, host)
      .catch((error: unknown) => this.say(describe(error)));
    await this.loadWorktrees(host);
  },
  /** Delete an idle worktree's build output, and say what it freed; null when it could not. */
  async removeBuildOutput(this: Store, host: string, folder: string, root: string): Promise<BuildOutputRemoved | null> {
    const removed = await this.link.call("worktrees/removeBuildOutput",
      { folder: folder as never, root: root as never, confirmed: false }, host)
      .catch((error: unknown) => { this.say(describe(error)); return null; });
    void this.loadWorktrees(host);
    return removed;
  },
  startRequestID(this: Store, host: string, folder: string): UUID {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.startRequests.get(key);
    if (held) return held;
    const id = crypto.randomUUID().toUpperCase() as UUID;
    this.startRequests.set(key, id);
    return id;
  },
  /** The start went through. The next one from this folder is a new request. */
  finishStartRequest(this: Store, host: string, folder: string): void {
    this.startRequests.delete(`${host}|${folderKey(folder)}`);
  },
  /** A runtime started behind the new-agent form, so its choices are real ones. */
  async draft(this: Store, host: string, runtimeID: string, cwd: string) {
    try {
      return await this.link.call("agents/options", { runtimeID, cwd: cwd as never, mcpServers: [] }, host);
    } catch (error) {
      return { failure: describe(error) };
    }
  },
  /** Files under the agent's folders for an `@` (#255): the host walks its own disk, as for the Remote. */
  async mentions(this: Store, host: string, agentID: string, term: string): Promise<FileMentionDTO[]> {
    return this.link.call("files/mention", { agentID: agentID as UUID, term }, host).catch(() => []);
  },
  discardDraft(this: Store, host: string, draftID: string): void {
    void this.link.call("agents/discardDraft", { draftID: draftID as UUID }, host).catch(() => {});
  },
  /**
   * Starts an agent; answers its id, or null with `problem` saying why. A runtime whose sandbox
   * will not start (064) answers what it said instead, for the form to offer Start without sandbox.
   */
  async start(this: Store, host: string, request: StartRequest): Promise<string | SandboxWillNotStart | { kept: KeptRequest } | { autoRefusal: string } | null> {
    try {
      return await this.link.call("agents/start", request, host);
    } catch (error) {
      // No runtime Auto may use can take it (FR-011): said over the prompt, which keeps it.
      if (error instanceof CallFailed && error.code === Failure.autoNoRuntime) return { autoRefusal: error.message };
      // Kept until its stopped workspace is up (#691 US3): the page shows it, then opens the agent.
      if (error instanceof CallFailed && error.code === Failure.kept) {
        const kept = this.noteKept(error);
        if (kept) return { kept };
      }
      if (error instanceof CallFailed && error.code === Failure.sandboxWillNotStart && isSandboxRefusal(error.data)) {
        return { ...error.data, message: error.message };
      }
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      this.say(describe(error));
      return null;
    }
  },
};
