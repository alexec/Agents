// Part of the Work (#5384): reducer.
import { preferencesSaid } from "../preferences";
import { fromDesktopControl } from "../liveTile";
import { batch } from "@preact/signals";
import type { Agent, AgentRemovedNotification, ResumingNotification, BrowserFrame, BrowserPageState, DesktopControlLiveFrame, LiveFrame, ElicitationNotification, EntryNotification, PermissionNotification, FolderSummary, TranscriptPage, WorkflowSummary, FilesChangedNotification, ShowFileNotification, WorkflowRemovedNotification, FolderRemovedNotification, DraftOptionsNotification, JSONValue, AccountProfile, WriteFailure, CloneNotification, LeaseSnapshot, HostedMCPSnapshot, MCPHealthSnapshot, DiskState, CapacityState, StoreNotes, EventsChange, PagesChangedNotification, PinsChangedNotification, Approval, Achievements, Multiplier, WorktreesSized, BackupState, DailySummarySettings, SummaryPage, PolicyState, MoveNotification, RequestUpdate, AgentChanges, ListRevision } from "../../protocol/generated";
import { takeEventsChange } from "../eventsWaiting";
import { folderKey, folderPath as agentFolderPath } from "../groups";
import { approvalID } from "../approvals";
import { Work } from "./work";
import { filesNamedAtMost, quietSettle, filesSettle, keepingLists, newestFirst, keepingLatestByID } from "./shared";

export const reducerMethods = {
  /** One notification from one host. Returns false for one this does not know. */
  apply(this: Work, method: string, params: unknown, host: string): boolean {
    switch (method) {
      case "agent/changed":
        this.upsertAgent(params as Agent, host);
        return true;
      case "daemon/policyStateChanged":
        this.policyStates.value = { ...this.policyStates.value, [host]: params as PolicyState };
        return true;
      case "runtimes/accountProfilesChanged":
        this.accountProfiles.value = { ...this.accountProfiles.value, [host]: params as AccountProfile[] };
        return true;
      case "folder/removed":
        // Deleted (#677); its sessions went before it, each by its own agent/removed.
        this.removeFolder((params as FolderRemovedNotification).folder, host);
        return true;
      case "folder/changed":
        this.upsertFolder(params as FolderSummary, host);
        return true;
      case "move/changed": {
        const move = params as MoveNotification;
        const { [move.agentID]: _, ...rest } = this.moves.value;
        const there = move.finished && move.problem === undefined;
        this.moves.value = there ? rest : { ...rest, [move.agentID]: move };
        if (move.finished) {
          const follow = this.moveFollows.get(move.agentID);
          this.moveFollows.delete(move.agentID);
          if (there) follow?.();
        }
        return true;
      }
      case "clone/changed": {
        // Every window hears it: a clone belongs to the host, not to whoever asked (027).
        const { clone, finished } = params as CloneNotification;
        const list = (this.clones.value[host] ?? []).filter((c) => c.id !== clone.id);
        this.clones.value = { ...this.clones.value, [host]: finished ? list : [...list, clone] };
        return true;
      }
      case "agent/entry":
        this.takeEntry(params as EntryNotification, host);
        return true;
      case "agent/permission": {
        const note = params as PermissionNotification;
        let list = (this.permissions.value[host] ?? []).filter((p) =>
          !(p.agentID === note.agentID && p.id === note.requestID));
        if (note.request) list = [...list, note.request];
        list.sort((a, b) => a.askedAt - b.askedAt);
        this.permissions.value = { ...this.permissions.value, [host]: list };
        return true;
      }
      case "agent/elicitation": {
        const note = params as ElicitationNotification;
        let list = (this.elicitations.value[host] ?? []).filter((e) => e.id !== note.requestID);
        if (note.request) list = [...list, note.request];
        this.elicitations.value = { ...this.elicitations.value, [host]: list };
        return true;
      }
      case "agents/draftOptions":
        this.draftOptions.value = params as DraftOptionsNotification;
        return true;
      case "events/changed":
        // Who waits now, for Status ▸ Events' grey line and Waiting now, and the event that came.
        this.events.value = { ...this.events.value, [host]: takeEventsChange(this.events.value[host], params as EventsChange) };
        return true;
      case "workflow/changed":
        this.placeWorkflow(params as WorkflowSummary, host);
        return true;
      case "requests/changed":
        this.placeRequest(host, (params as RequestUpdate).request);
        return true;
      case "pins/changed": {
        const note = params as PinsChangedNotification;
        this.pins.value = { ...this.pins.value, [`${host}|${folderKey(note.folder)}`]: note.pins };
        this.sessionPins.value = { ...this.sessionPins.value, [`${host}|${folderKey(note.folder)}`]: note.sessions ?? [] };
        this.workflowPins.value = { ...this.workflowPins.value, [`${host}|${folderKey(note.folder)}`]: note.workflows ?? [] };
        this.serverViews.value = { ...this.serverViews.value, [`${host}|${folderKey(note.folder)}`]: note.views ?? [] };
        this.reviewPulls.value = { ...this.reviewPulls.value, [`${host}|${folderKey(note.folder)}`]: note.reviews ?? [] };
        this.checkSuggestions.value = { ...this.checkSuggestions.value, [`${host}|${folderKey(note.folder)}`]: note.suggestions ?? [] };
        return true;
      }
      case "pages/changed": {
        // A burst of writes: the pages read again once it is quiet, and with the stamp they hold (#291).
        const note = params as PagesChangedNotification;
        const key = `${host}|${folderKey(note.folder)}`;
        clearTimeout(this.pageSettle.get(key));
        this.pageSettle.set(key, setTimeout(() => {
          this.pageSettle.delete(key);
          this.pageRevisions.value = { ...this.pageRevisions.value, [key]: (this.pageRevisions.peek()[key] ?? 0) + 1 };
        }, quietSettle));
        return true;
      }
      case "workflow/removed": {
        const note = params as WorkflowRemovedNotification;
        const key = `${host}|${folderKey(note.folder)}`;
        const held = this.workflows.peek()[key];
        if (held) this.writeWorkflows(key, held.filter((w) => w.workflow.workflowID !== note.workflowID));
        return true;
      }
      case "browser/frame":
        this.browserFrame.value = { host, frame: params as BrowserFrame };
        return true;
      case "browser/pageChanged":
        this.browserStates.value = { ...this.browserStates.peek(), [host]: params as BrowserPageState };
        return true;
      case "live/frame": {
        const frame = params as LiveFrame;
        this.liveFrames.value = { ...this.liveFrames.peek(), [frame.source]: { host, frame, heardAt: Date.now() } };
        return true;
      }
      // A host from before live/frame: its screen frames.
      case "desktopControl/liveFrame":
        this.liveFrames.value = { ...this.liveFrames.peek(),
          screen: { host, frame: fromDesktopControl(params as DesktopControlLiveFrame), heardAt: Date.now() } };
        return true;
      case "agent/showFile": {
        const note = params as ShowFileNotification;
        this.noteChartHint(host, note.file.path, note.file.chart);
        this.shownFile.value = { host, agentID: note.agentID, path: note.file.path, line: note.file.line, at: Date.now() };
        return true;
      }
      case "files/changed": {
        // A build writes hundreds of files in a burst: the panes read again once it settles (#170).
        const note = params as FilesChangedNotification;
        const key = `${host}|${note.agentID}`;
        // Too many to name (#216): the host says `many`, and every pane for the agent reads again.
        const settling = this.filesSettling.get(key);
        const folders = new Set([...(settling?.folders ?? []), ...note.folders]);
        const many = (settling?.many ?? false) || note.many === true || folders.size > filesNamedAtMost;
        clearTimeout(settling?.timer);
        this.filesSettling.set(key, { folders: many ? new Set() : folders, many, timer: setTimeout(() => {
          this.filesSettling.delete(key);
          this.filesChanged.value = { host, agentID: note.agentID, folders: many ? [] : [...folders], many, at: Date.now() };
        }, filesSettle) });
        return true;
      }
      case "storage/writeFailed":
        // Something nobody was waiting on was not kept: a full disk, or a folder refusing
        // writes. Said, as the window and the Remote say it (#88).
        this.say((params as WriteFailure).message);
        return true;
      case "agent/resuming": {
        const note = params as ResumingNotification;
        const held = (this.resuming.value[host] ?? []).filter((id) => id !== note.agentID);
        this.resuming.value = { ...this.resuming.value, [host]: note.isResuming ? [...held, note.agentID] : held };
        return true;
      }
      case "resources/changed":
        this.leases.value = { ...this.leases.value, [host]: params as LeaseSnapshot };
        return true;
      case "mcp/hostedChanged":
        this.hostedMCP.value = { ...this.hostedMCP.value, [host]: params as HostedMCPSnapshot };
        return true;
      case "mcp/healthChanged":
        this.mcpHealth.value = { ...this.mcpHealth.value, [host]: params as MCPHealthSnapshot };
        return true;
      case "disk/changed":
        this.disk.value = { ...this.disk.value, [host]: params as DiskState };
        return true;
      case "capacity/changed":
        this.capacity.value = { ...this.capacity.value, [host]: params as CapacityState };
        return true;
      case "backups/changed":
        if (this.isMac(host)) { this.backups.value = params as BackupState; this.backupsAt.value = Date.now(); }
        return true;
      case "worktrees/sized": {
        const held = { ...(this.worktreeSizes.value[host] ?? {}) };
        for (const note of (params as WorktreesSized).sizes) held[note.root] = note.size;
        this.worktreeSizes.value = { ...this.worktreeSizes.value, [host]: held };
        return true;
      }
      case "store/notesChanged":
        this.storeNotes.value = { ...this.storeNotes.value, [host]: (params as StoreNotes).notes };
        return true;
      case "achievements/changed":
        this.takeAchievements(host, params as Achievements);
        return true;
      case "multiplier/changed":
        this.multiplier.value = { ...this.multiplier.value, [host]: params as Multiplier };
        this.usageRead(host, "multiplier");
        return true;
      case "preferences/changed":
        if (this.isMac(host)) preferencesSaid(params as Record<string, JSONValue>);
        return true;
      case "dailySummary/changed":
        if (this.isMac(host)) this.dailySummary.value = params as DailySummarySettings;
        return true;
      case "summaries/changed":
        if (this.isMac(host)) this.summaryPages.value = params as SummaryPage[];
        return true;
      case "modes/changed":
        this.rememberedModes.value = { ...this.rememberedModes.value, [host]: params as Record<string, JSONValue> };
        return true;
      case "agent/removed": {
        const { agentID } = params as AgentRemovedNotification;
        const held = this.agents.value[host] ?? [];
        const gone = held.find((a) => a.id === agentID);
        batch(() => {
          if (gone) this.setAgents(host, held.filter((a) => a !== gone), [agentFolderPath(gone)]);
          this.permissions.value = { ...this.permissions.value,
            [host]: (this.permissions.value[host] ?? []).filter((p) => p.agentID !== agentID) };
          this.elicitations.value = { ...this.elicitations.value,
            [host]: (this.elicitations.value[host] ?? []).filter((e) => e.agentID !== agentID) };
        });
        return true;
      }
      default:
        return false;
    }
  },
  removeFolder(this: Work, folder: string, host: string): void {
    const list = (this.folders.value[host] ?? []).filter((p) => folderKey(p.folder.folder) !== folderKey(folder));
    this.folders.value = { ...this.folders.value, [host]: list };
  },
  upsertFolder(this: Work, summary: FolderSummary, host: string): void {
    const list = (this.folders.value[host] ?? [])
      .filter((p) => folderKey(p.folder.folder) !== folderKey(summary.folder.folder));
    this.folders.value = { ...this.folders.value, [host]: [...list, this.hidingAnswered(summary, host)] };
  },
  /** A host's summary of a folder, less the approvals being answered here (#4814). */
  hidingAnswered(this: Work, summary: FolderSummary, host: string): FolderSummary {
    if (this.answeringApprovals.size === 0) return summary;
    const prefix = Work.approvalSlot(host, summary.folder.folder, "");
    const listed = summary.approvals ?? [];
    for (const [slot, held] of this.answeringApprovals) {
      if (slot.startsWith(prefix) && !listed.some((a) => approvalID(a) === approvalID(held.approval))) held.gone = true;
    }
    const approvals = listed.filter((a) => !this.answeringApprovals.has(prefix + approvalID(a)));
    return approvals.length === listed.length ? summary : { ...summary, approvals };
  },
  /** Every summary of a host's list, less the approvals being answered here. */
  hidingAnsweredIn(this: Work, summaries: FolderSummary[], host: string): FolderSummary[] {
    return this.answeringApprovals.size === 0 ? summaries : summaries.map((p) => this.hidingAnswered(p, host));
  },
  /**
   * An approval as the page shows it, found also while its answer is on its way (#4814): the Review
   * page stays on it, to say a refusal in place, while its row has already gone.
   */
  approvalShown(this: Work, host: string, folder: string, id: string): Approval | undefined {
    const summary = (this.folders.value[host] ?? []).find((p) => folderKey(p.folder.folder) === folderKey(folder));
    return summary?.approvals?.find((a) => approvalID(a) === id)
      ?? this.answeringApprovals.get(Work.approvalSlot(host, folder, id))?.approval;
  },
  /**
   * Answer an approval: it leaves its folder's list at once, before the host has the answer
   * (#4814), and comes back when `send` answers null (it did not go), unless the host's list
   * meanwhile no longer has it.
   */
  async answeringApproval<T>(this: Work, host: string, folder: string, id: string, send: () => Promise<T | null>): Promise<T | null> {
    const slot = Work.approvalSlot(host, folder, id);
    const list = this.folders.peek()[host] ?? [];
    const summary = list.find((p) => folderKey(p.folder.folder) === folderKey(folder));
    const approval = summary?.approvals?.find((a) => approvalID(a) === id);
    if (!summary || !approval || this.answeringApprovals.has(slot)) return send();
    const held = { approval, gone: false };
    this.answeringApprovals.set(slot, held);
    this.placeFolder({ ...summary, approvals: (summary.approvals ?? []).filter((a) => approvalID(a) !== id) }, host);
    let sent: T | null = null;
    try {
      sent = await send();
    } finally {
      this.answeringApprovals.delete(slot);
      const now = (this.folders.peek()[host] ?? []).find((p) => folderKey(p.folder.folder) === folderKey(folder));
      if (sent === null && !held.gone && now && !(now.approvals ?? []).some((a) => approvalID(a) === id)) {
        this.placeFolder({ ...now, approvals: [...(now.approvals ?? []), approval] }, host);
      }
    }
    return sent;
  },
  /** A summary into its place in the host's list, as it is: no approval hidden or shown again. */
  placeFolder(this: Work, summary: FolderSummary, host: string): void {
    const list = this.folders.peek()[host] ?? [];
    this.folders.value = { ...this.folders.value,
      [host]: list.map((p) => (folderKey(p.folder.folder) === folderKey(summary.folder.folder) ? summary : p)) };
  },
  /**
   * One agent as it is now, put where its activity sorts it. Only its folder's list, and the
   * one it left if it moved, are made again (#170).
   */
  upsertAgent(this: Work, heard: Agent, host: string): void {
    const list = [...(this.agents.value[host] ?? [])];
    const at = list.findIndex((a) => a.id === heard.id);
    // An archived session this page has let go of, or never had, stays out: the live ones and a
    // page of the rest is all it holds (#170, #203).
    if (at < 0 && heard.state === "archived") return;
    const was = at >= 0 ? list.splice(at, 1)[0] : undefined;
    // Lean unless its lists moved and this page shows it (#203).
    const agent = keepingLists(heard, was);
    // Newest first, after any as new: where a stable sort of the list with it last puts it.
    let into = 0;
    while (into < list.length && list[into]!.lastActivityAt >= agent.lastActivityAt) into++;
    list.splice(into, 0, agent);
    this.setAgents(host, list, was ? [agentFolderPath(was), agentFolderPath(agent)] : [agentFolderPath(agent)]);
  },
  /** One host's agents as it just listed them; every other host's are left alone. */
  replaceAgents(this: Work, listed: Agent[], host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    this.setAgents(host, newestFirst(listed.map((a) => keepingLists(a, held.get(a.id)))));
  },
  /** Archived agents of one folder, listed when the fold opens, added beside the live ones. */
  addAgents(this: Work, listed: Agent[], host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    const incoming = new Set(listed.map((l) => l.id));
    const kept = [...held.values()].filter((a) => !incoming.has(a.id));
    this.setAgents(host, newestFirst([...kept, ...listed.map((a) => keepingLists(a, held.get(a.id)))]),
      listed.map(agentFolderPath));
  },
  /**
   * What changed on a host since the point held (#4794), in place of its whole list: each changed
   * record laid on, each removed one let go, and the new point kept. An archived one not held stays
   * out, as `agent/changed` of one does. What this device's copy drew is the host's now.
   */
  takeChanges(this: Work, changed: Agent[], changes: AgentChanges, host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    const gone = new Set(changes.removed);
    const touched: string[] = [];
    for (const agent of changed) {
      const was = held.get(agent.id);
      if (!was && agent.state === "archived") continue;
      if (was) touched.push(agentFolderPath(was));
      touched.push(agentFolderPath(agent));
      held.set(agent.id, keepingLists(agent, was));
    }
    for (const id of gone) {
      const was = held.get(id);
      if (!was) continue;
      touched.push(agentFolderPath(was));
      held.delete(id);
    }
    batch(() => {
      this.setAgents(host, newestFirst([...held.values()]), touched);
      this.listPoints.set(host, { epoch: changes.epoch, revision: changes.revision });
      this.answered(host);
    });
  },
  /** A host's catch-up said where its list is (#4794); none, from a host before it, asks for all next time. */
  notePoint(this: Work, changes: AgentChanges | undefined, host: string): void {
    if (changes) this.listPoints.set(host, { epoch: changes.epoch, revision: changes.revision });
    else this.listPoints.delete(host);
  },
  /** The open chat's host's count of entries at its last page (#4794): what the copy keeps as its end. */
  chatEnd(this: Work): number | null {
    return this.transcriptEnd;
  },
  /** Where a host's sessions held here are in its order of changes (#4794). */
  listPoint(this: Work, host: string): ListRevision | undefined {
    return this.listPoints.get(host);
  },
  /**
   * The entries written since the open chat's last page (#4794), asked `from` its end, laid after
   * what is held with what was heard meanwhile. False, and nothing changed, when the page does not
   * start where the held one ended: the chat then opens whole.
   */
  takeResumed(this: Work, page: TranscriptPage): boolean {
    const end = this.transcriptEnd;
    if (end === null || page.firstIndex !== end || page.total < end) return false;
    const entries = keepingLatestByID([...this.entries.value, ...page.entries, ...(this.heardSincePage ?? [])]);
    this.heardSincePage = null;
    this.transcriptEnd = page.total;
    batch(() => {
      this.transcriptLoadFailure.value = null;
      this.transcriptSource.value = "host";
      this.refold(entries);
    });
    return true;
  },
  /**
   * One folder's archived agents let go, when its Archived fold closes: the page holds the live
   * agents and a page of archived ones per open fold, no more (#170). The open session stays.
   */
  dropArchived(this: Work, host: string, folder: string): void {
    const key = folderKey(folder);
    const watching = this.watching.value;
    const held = this.agents.value[host] ?? [];
    const kept = held.filter((a) => a.state !== "archived" || agentFolderPath(a) !== key
      || (watching?.host === host && watching.session === a.id));
    if (kept.length !== held.length) this.setAgents(host, kept, [key]);
  },
};
