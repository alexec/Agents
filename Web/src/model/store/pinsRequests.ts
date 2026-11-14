// Part of the Store (#5384): pinsRequests.
import { deferParams, isDeferred, type Later } from "../later";
import { isTerminalRequest, secretUsesAskedBy } from "../secretUse";
import type { WorkflowSummary, UUID, FileStamp, PinView, ReviewPull, CheckSuggestion, ViewPin, Request as PersonRequest, RequestUpdate } from "../../protocol/generated";
import { toWireDate } from "../../protocol/dates";
import { folderKey } from "../groups";
import { omitting } from "../pendingWrites";
import { laterUndo } from "../changeUndo";
import type { Store } from "../store";

export const pinsRequestsMethods = {
  // MARK: Pinned pages (#159)

  pinsIn(this: Store, host: string, folder: string): PinView[] {
    return this.pins.value[`${host}|${folderKey(folder)}`] ?? [];
  },
  /** A folder's servers' list views (#2032), the hidden ones too, in the servers' order. */
  serverViewsIn(this: Store, host: string, folder: string): PinView[] {
    return this.serverViews.value[`${host}|${folderKey(folder)}`] ?? [];
  },
  /** A pin or a server's list view at this path: what a sidebar row opens. */
  pinOrViewIn(this: Store, host: string, folder: string, path: string): PinView | undefined {
    return this.pinsIn(host, folder).find((p) => p.path === path) ?? this.serverViewsIn(host, folder).find((p) => p.path === path);
  },
  /** Hide or Show on a server's list view (#2032): shown at once, then the host told. */
  async setViewHidden(this: Store, host: string, folder: string, uri: string, hidden: boolean): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    this.serverViews.value = { ...this.serverViews.value,
      [key]: this.serverViewsIn(host, folder).map((v) => {
        if (v.path !== uri) return v;
        const { hidden: _was, ...rest } = v;
        return hidden ? { ...rest, hidden: true } : rest;
      }) };
    await this.act("pins/hideView", { folder: folder as never, uri, hidden }, host);
  },
  /**
   * A folder's open requests to the person, deferred or not, whose asker is held and not archived
   * (#3864), oldest first: each stands for its asker, in Needs You or in Later (#4236).
   */
  openPersonRequestsIn(this: Store, host: string, folder: string): PersonRequest[] {
    const key = folderKey(folder);
    return (this.personRequests.value[host] ?? []).filter((r) => folderKey(r.folder) === key
      && r.askedBy !== undefined && (this.agent(host, r.askedBy)?.state ?? "archived") !== "archived");
  },
  /** A folder's requests in Needs You's rows and count: the open ones not in Later (#4236). */
  personRequestsIn(this: Store, host: string, folder: string): PersonRequest[] {
    return this.openPersonRequestsIn(host, folder).filter((r) => !isDeferred(r));
  },
  /** A folder's deferred requests (#4236): the Later group's rows, in no count. */
  laterRequestsIn(this: Store, host: string, folder: string): PersonRequest[] {
    return this.openPersonRequestsIn(host, folder).filter(isDeferred);
  },
  /** The uses of a secret with Ask before use that a session waits on (#4918), oldest first, Later's too: each is a card in its chat as well as a row in Needs You. */
  secretUsesAskedBy(this: Store, host: string, session: string): PersonRequest[] {
    return secretUsesAskedBy(this.personRequests.value[host] ?? [], session);
  },
  /** A machine's open requests from a terminal's agents-secret (#4179): no session asked them, so no folder lists them. Not the deferred ones. */
  terminalRequests(this: Store, host: string): PersonRequest[] {
    return (this.personRequests.value[host] ?? []).filter((r) => isTerminalRequest(r) && !isDeferred(r));
  },
  /** A terminal's deferred requests (#4236), in Later with the rest. */
  laterTerminalRequests(this: Store, host: string): PersonRequest[] {
    return (this.personRequests.value[host] ?? []).filter((r) => isTerminalRequest(r) && isDeferred(r));
  },
  /** Later on a request (#4236): out of Needs You until its time, or until the person is next at the Mac. */
  async deferRequest(this: Store, host: string, request: string, later: Later): Promise<void> {
    const params = deferParams(request, later);
    const at = toWireDate(new Date());
    const deferred = params.atMac ? { atMac: true, at } : params.until === undefined ? { at } : { until: params.until, at };
    const before = (this.personRequests.peek()[host] ?? []).find((r) => r.id === request);
    const done = await this.changingRequest(host, request, (r) => ({ ...r, deferred }), () => this.act("requests/defer", params, host));
    // Undo is Bring Back Now (#4793).
    if (done && before) this.offerUndo(host, laterUndo(before));
  },
  /**
   * Later or Bring Back, drawn at once (#4786), the host's answer placed when it comes, and the
   * request put back as it was when the call did not go, unless the host changed it meanwhile.
   */
  async changingRequest(this: Store, host: string, id: string, draw: (r: PersonRequest) => PersonRequest,
                                send: () => Promise<RequestUpdate | null>): Promise<boolean> {
    const held = (this.personRequests.peek()[host] ?? []).find((r) => r.id === id);
    const shown = held ? draw(held) : null;
    if (shown) this.placeRequest(host, shown);
    const changed = await send();
    if (changed) this.placeRequest(host, changed.request);
    else if (held && (this.personRequests.peek()[host] ?? []).find((r) => r.id === id) === shown) this.placeRequest(host, held);
    return changed !== null;
  },
  /** Bring Back Now (#4236): a deferred request back into Needs You at once. */
  async undeferRequest(this: Store, host: string, request: string): Promise<void> {
    await this.changingRequest(host, request, (r) => omitting(r, "deferred"),
      () => this.act("requests/undefer", { id: request as never }, host));
  },
  /** A folder's pull requests waiting for the person's approval (#3330), newest first. */
  reviewPullsIn(this: Store, host: string, folder: string): ReviewPull[] {
    return this.reviewPulls.value[`${host}|${folderKey(folder)}`] ?? [];
  },
  /** Dismiss on a pull request in For Review (#3330): gone at once, then the host told, which keeps it out for good. */
  async dismissReview(this: Store, host: string, folder: string, url: string): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    this.reviewPulls.value = { ...this.reviewPulls.value, [key]: this.reviewPullsIn(host, folder).filter((p) => p.url !== url) };
    await this.act("reviews/dismiss", { folder: folder as never, url: url as never }, host);
  },
  /** A press on a pull request in For Review (#3464): drawn read at once, then the host told, which keeps it for every client. */
  async openReview(this: Store, host: string, folder: string, url: string): Promise<void> {
    const pulls = this.reviewPullsIn(host, folder);
    if (!pulls.some((p) => p.url === url && !p.opened)) return;
    const key = `${host}|${folderKey(folder)}`;
    this.reviewPulls.value = { ...this.reviewPulls.value, [key]: pulls.map((p) => (p.url === url ? { ...p, opened: true } : p)) };
    await this.act("reviews/open", { folder: folder as never, url: url as never }, host);
  },
  /** A folder's suggestions of the daily checks (#3331), newest first. */
  checkSuggestionsIn(this: Store, host: string, folder: string): CheckSuggestion[] {
    return this.checkSuggestions.value[`${host}|${folderKey(folder)}`] ?? [];
  },
  dropSuggestion(this: Store, host: string, folder: string, id: string): void {
    const key = `${host}|${folderKey(folder)}`;
    this.checkSuggestions.value = { ...this.checkSuggestions.value, [key]: this.checkSuggestionsIn(host, folder).filter((s) => s.id !== id) };
  },
  /** Start on a suggestion of the daily checks (#3331): the host starts a session with its prompt; answers its id, or null. */
  async startSuggestion(this: Store, host: string, folder: string, id: string): Promise<string | null> {
    const started = await this.act("suggestions/start", { folder: folder as never, id }, host);
    if (started) this.dropSuggestion(host, folder, id);
    return started;
  },
  /** Dismiss on a suggestion of the daily checks (#3331): gone at once, then the host told, which keeps it out for good. */
  async dismissSuggestion(this: Store, host: string, folder: string, id: string): Promise<void> {
    this.dropSuggestion(host, folder, id);
    await this.act("suggestions/dismiss", { folder: folder as never, id }, host);
  },
  /** A file of the folder's: a pinned page, or what an HTML page draws from. */
  readPage(this: Store, host: string, folder: string, path: string, knownStamp?: FileStamp) {
    return this.link.call("pins/read", { folder: folder as never, path, ...(knownStamp ? { knownStamp } : {}) }, host);
  },
  async writePage(this: Store, host: string, folder: string, path: string, text: string): Promise<boolean> {
    return (await this.act("pins/write", { folder: folder as never, path, text }, host)) !== null;
  },
  async pin(this: Store, host: string, folder: string, path: string): Promise<void> {
    const pins = await this.act("pins/pin", { folder: folder as never, path }, host);
    if (pins) this.pins.value = { ...this.pins.value, [`${host}|${folderKey(folder)}`]: pins };
  },
  /** A chat's view pinned to its folder (#189): keyed by its ui:// address. Answers whether
   *  it was; a refusal is said in `problem`. */
  async pinView(this: Store, host: string, folder: string, view: ViewPin): Promise<boolean> {
    const pins = await this.act("pins/pin", { folder: folder as never, path: view.uri, view }, host);
    if (pins) this.pins.value = { ...this.pins.value, [`${host}|${folderKey(folder)}`]: pins };
    return pins !== null;
  },
  async unpin(this: Store, host: string, folder: string, path: string): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    this.pins.value = { ...this.pins.value, [key]: this.pinsIn(host, folder).filter((p) => p.path !== path) };
    await this.act("pins/unpin", { folder: folder as never, path }, host);
  },
  /** A drop or a Move item: shown at once, then the whole order sent once. */
  async arrangePins(this: Store, host: string, folder: string, paths: string[]): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.pinsIn(host, folder);
    this.pins.value = { ...this.pins.value, [key]: paths.flatMap((path) => held.filter((p) => p.path === path)) };
    await this.act("pins/arrange", { folder: folder as never, paths }, host);
  },
  // MARK: Pinned sessions (#180)

  sessionPinsIn(this: Store, host: string, folder: string): string[] {
    return this.sessionPins.value[`${host}|${folderKey(folder)}`] ?? [];
  },
  /** Pin or Unpin from a session's menu: shown at once, then the host told. */
  async setPinned(this: Store, host: string, folder: string, agentID: string, pinned: boolean): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.sessionPinsIn(host, folder).filter((id) => id !== agentID);
    this.sessionPins.value = { ...this.sessionPins.value, [key]: pinned ? [...held, agentID] : held };
    await this.act(pinned ? "pins/pinSession" : "pins/unpinSession",
      { folder: folder as never, agentID: agentID as UUID }, host);
  },
  /** A Move item among the pinned sessions: shown at once, then the whole order sent once. */
  async arrangeSessionPins(this: Store, host: string, folder: string, ids: string[]): Promise<void> {
    this.sessionPins.value = { ...this.sessionPins.value, [`${host}|${folderKey(folder)}`]: ids };
    await this.act("pins/arrangeSessions", { folder: folder as never, agentIDs: ids as UUID[] }, host);
  },
  workflowPinsIn(this: Store, host: string, folder: string): string[] {
    return this.workflowPins.value[`${host}|${folderKey(folder)}`] ?? [];
  },
  /** Pin or Unpin a workflow (#432) from its menu or page: shown at once, then the host told. */
  async setWorkflowPinned(this: Store, host: string, folder: string, workflowID: string, pinned: boolean): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.workflowPinsIn(host, folder).filter((id) => id !== workflowID);
    this.workflowPins.value = { ...this.workflowPins.value, [key]: pinned ? [...held, workflowID] : held };
    await this.act(pinned ? "pins/pinWorkflow" : "pins/unpinWorkflow", { folder: folder as never, workflowID }, host);
  },
  /** A Move item among the pinned workflows: shown at once, then the whole order sent once. */
  async arrangeWorkflowPins(this: Store, host: string, folder: string, ids: string[]): Promise<void> {
    this.workflowPins.value = { ...this.workflowPins.value, [`${host}|${folderKey(folder)}`]: ids };
    await this.act("pins/arrangeWorkflows", { folder: folder as never, workflowIDs: ids }, host);
  },
  /** Run now (US5). The session it starts arrives as any other does, by agent/changed. */
  async runWorkflow(this: Store, host: string, summary: WorkflowSummary): Promise<void> {
    const ran = await this.act("workflows/run", { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID }, host);
    if (ran) this.placeWorkflow(ran, host);
  },
  /** Turn Off / Turn On (#100): it keeps its place on the list either way. */
  async setWorkflowEnabled(this: Store, host: string, summary: WorkflowSummary, enabled: boolean): Promise<void> {
    const changed = await this.act("workflows/enable",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, enabled }, host);
    if (changed) this.placeWorkflow(changed, host);
  },
  /** Clear a server's event trigger's missed-events mark (#383). */
  async clearMCPMissed(this: Store, host: string, summary: WorkflowSummary, name: string, server: string | undefined): Promise<void> {
    const changed = await this.act("workflows/mcpTrigger/clearMissed",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, name,
        ...(server !== undefined ? { server } : {}) }, host);
    if (changed) this.placeWorkflow(changed, host);
  },
  /** Approve (#142): the digest is what the page was showing, so a file changed since still waits. */
  async approveWorkflow(this: Store, host: string, summary: WorkflowSummary): Promise<void> {
    await this.answerWorkflow(host, summary, "workflows/approve");
  },
  /** Deny on this host only (#391): it does not run here, its file is untouched, and Approve takes it back. */
  async denyWorkflow(this: Store, host: string, summary: WorkflowSummary): Promise<void> {
    await this.answerWorkflow(host, summary, "workflows/deny");
  },
  async answerWorkflow(this: Store, host: string, summary: WorkflowSummary,
    method: "workflows/approve" | "workflows/deny"): Promise<void> {
    const file = summary.awaitingApproval ?? summary.deniedHere;
    if (!file) return;
    const changed = await this.act(method,
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, digest: file.digest }, host);
    if (changed) this.placeWorkflow(changed, host);
  },
  /** Archive or Unarchive (#142), as the window's page has them. */
  async setWorkflowArchived(this: Store, host: string, summary: WorkflowSummary, archived: boolean): Promise<void> {
    const changed = await this.act("workflows/archive",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, archived }, host);
    if (changed) this.placeWorkflow(changed, host);
  },
  /** An edited ready-made copy (#4075): the newer version over it, or the copy kept and the notice hidden. */
  async answerReadyMade(this: Store, host: string, summary: WorkflowSummary, take: boolean): Promise<void> {
    await this.act(take ? "workflows/readyMade/take" : "workflows/readyMade/keep",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID }, host);
  },
  /** Delete its workflow file and let workflow/removed update every open view (#605). */
  async deleteWorkflow(this: Store, host: string, summary: WorkflowSummary): Promise<boolean> {
    const deleted = await this.act("workflows/delete",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID }, host);
    return deleted !== null;
  },
};
