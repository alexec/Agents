// Part of the Store (#5384): prompting.
import type { Agent, Attachment, UUID, FileStamp, SandboxChoice, MoveToMachineAnswer, ProblemReport, ProblemReportRequest } from "../../protocol/generated";
import { Failure } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { describe } from "../errors";
import type { SaveOutcome } from "../sourceEdit";
import { log } from "../../log";
import { giveBackInto } from "../promptQuote";
import { scopeRoot } from "../fileWatch";
import { dropboxRefusal, dropboxRequest } from "../dropbox";
import { goOnRequest } from "../limits";
import { Capability } from "../../protocol/capabilities.generated";
import { type AgentWrite } from "../pendingWrites";
import { type Sending, willQueue } from "../sending";
import { type ChangeUndo, changeUndoLine, changeUndoMenu, unarchivedUndo } from "../changeUndo";
import { mark } from "../marks";
import type { Store } from "../store";
import { type AgentAct, sentBeforeEdit } from "./shared";

export const promptingMethods = {
  async prompt(this: Store, host: string, agentID: string, text: string, attachments: Attachment[]): Promise<boolean> {
    // The person's bubble at once (#4814), unless it will wait in the queue, which draws its own.
    const shown = this.agent(host, agentID);
    const bubble: Sending | null = shown && !willQueue(shown) ? { id: `send-${++this.nextSend}`, text, answered: false } : null;
    if (bubble) this.setSending(host, agentID, [...this.sending.peek()[`${host}|${agentID}`] ?? [], bubble]);
    const settle = (went: boolean) => {
      if (!bubble) return;
      const going = this.sending.peek()[`${host}|${agentID}`] ?? [];
      const watched = this.watching.peek();
      // Went: kept until the host's entry for it, in the chat that will hear it.
      const keep = went && watched?.host === host && watched.session === agentID;
      this.setSending(host, agentID, keep
        ? going.map((s) => (s.id === bubble.id ? { ...s, answered: true } : s))
        : going.filter((s) => s.id !== bubble.id));
    };
    try {
      mark("send");
      this.echoAwaited = true;
      await this.link.call("agents/prompt", { agentID: agentID as UUID, text, attachments, from: "person" }, host);
      settle(true);
      return true;
    } catch (error) {
      settle(false);
      // Kept for a stopped workspace (#691 US3): its bubble says so, and it goes when the host is up.
      if (error instanceof CallFailed && error.code === Failure.kept && this.noteKept(error)) return true;
      // Its folder has gone (#119): said with the ways on, carrying what was typed.
      if (error instanceof CallFailed && error.code === Failure.folderGone) {
        this.folderGone.value = { host, agentID, message: error.message, text, attachments };
        return false;
      }
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      this.say(describe(error));
      return false;
    }
  },
  /**
   * Continue in the folder (#119): a successor that reads this session and carries on,
   * with whatever was typed. Answers its id, or null with `problem` saying why.
   */
  async continueInFolder(this: Store, host: string, agentID: string, text = "", attachments: Attachment[] = []): Promise<string | null> {
    return this.act("agents/continueInFolder",
      { agentID: agentID as UUID, text, attachments, requestID: crypto.randomUUID().toUpperCase() as UUID }, host);
  },
  /**
   * Continue in New (#999): a session in the same folder that reads this one and carries on, on the
   * runtime's account for new sessions. Answers its id, or null with `problem` saying why.
   */
  async continueInNew(this: Store, host: string, agentID: string, onAuto = false): Promise<string | null> {
    return this.act("agents/continueInNew", { agentID: agentID as UUID, requestID: crypto.randomUUID().toUpperCase() as UUID,
      ...(onAuto ? { auto: true } : {}) }, host);
  },
  /**
   * Branch (#342): a new session that carries this one's history so far, the original left alone.
   * Answers its id, or null with `problem` saying why.
   */
  async fork(this: Store, host: string, agentID: string): Promise<string | null> {
    return this.act("agents/fork", { agentID: agentID as UUID }, host);
  },
  /**
   * Branch from Here (#1658): a new session that goes on from just before the person's prompt
   * `entryID`, with that prompt's `text` in its prompt bar to change and send. Answers its id, or
   * null with `problem` saying why, in the host's words.
   */
  async branchFrom(this: Store, host: string, agentID: string, entryID: string, text: string): Promise<string | null> {
    const id = await this.act("agents/branchFrom", { agentID: agentID as UUID, entryID: entryID as UUID }, host);
    if (!id) return null;
    const key = `${host}|${id}`;
    const draft = this.drafts.get(key);
    this.drafts.set(key, { text: giveBackInto(text, draft?.text ?? ""), attachments: draft?.attachments ?? [] });
    return id;
  },
  /** Recreate the worktree from its branch (#119); the row follows from `agent/changed`. */
  async recreateWorktree(this: Store, host: string, agentID: string): Promise<void> {
    const agent = await this.act("agents/recreateWorktree", { agentID: agentID as UUID }, host);
    if (agent) this.apply("agent/changed", agent, host);
  },
  /** Carry on when the allowance is back, or no longer (#1859); the row follows from `agent/changed`. */
  /** Pause on touch's two answers (#3004, US3): Resume drives on; Take Over lets go of the screen. */
  async answerDesktopControlPause(this: Store, host: string, agentID: string, method: "desktopControl/resume" | "desktopControl/takeOver"): Promise<void> {
    await this.act(method, { agentID: agentID as UUID }, host);
  },
  async continueWhenBack(this: Store, host: string, agentID: string, on: boolean): Promise<void> {
    const agent = await this.act(on ? "agents/continueWhenBack" : "agents/cancelContinue", { agentID: agentID as UUID }, host);
    if (agent) this.apply("agent/changed", agent, host);
  },
  /** Start now (#5156): a queued session at once, past the running limit; the host refuses it past the total, and says why. */
  async startNow(this: Store, host: string, agentID: string): Promise<void> {
    const write: AgentWrite = { kind: "startNow" };
    await this.acting(agentID, "agents/startNow", () => this.optimistic(host, agentID, write, async () =>
      await this.act("agents/startNow", { agentID: agentID as UUID }, host, write) !== null));
  },
  async sendNow(this: Store, host: string, agentID: string, promptID: string): Promise<void> {
    const write: AgentWrite = { kind: "sendNow", promptID };
    await this.acting(agentID, { sendNow: promptID }, () => this.optimistic(host, agentID, write, async () =>
      await this.act("agents/sendNow", { agentID: agentID as UUID, promptID: promptID as UUID }, host, write) !== null));
  },
  /** Who an action goes to, as the pending mark says it: "your Mac", or the host's name. */
  recipient(this: Store, host: string): string {
    return this.isMac(host) ? "your Mac" : this.hosts.value.find((h) => h.id === host)?.name ?? "the machine";
  },
  async acting(this: Store, agentID: string, act: AgentAct, run: () => Promise<unknown>): Promise<void> {
    if (this.onItsWay.value[agentID]) return;
    this.onItsWay.value = { ...this.onItsWay.value, [agentID]: act };
    try {
      await run();
    } finally {
      const { [agentID]: _done, ...rest } = this.onItsWay.value;
      this.onItsWay.value = rest;
    }
  },
  async unqueue(this: Store, host: string, agentID: string, promptID: string): Promise<void> {
    await this.act("agents/unqueue", { agentID: agentID as UUID, promptID: promptID as UUID }, host);
  },
  /**
   * New words for the person's queued prompt, in its place in the queue (#1552). When it was sent
   * or taken back first, or the call failed, the words go into the prompt bar under `draftKey`.
   */
  async editQueued(this: Store, host: string, agentID: string, promptID: string, text: string, draftKey: string): Promise<void> {
    const result = await this.act("agents/editQueued", { agentID: agentID as UUID, promptID: promptID as UUID, text }, host);
    if (result?.edited) return;
    this.offeredPrompt.value = { draftKey, text };
    if (result) this.say(sentBeforeEdit);
  },
  /** One task an agent left running, and nothing else it is doing (057, #253). */
  async stopBackground(this: Store, host: string, agentID: string, itemID: string): Promise<void> {
    await this.act("agents/stopBackground", { agentID: agentID as UUID, itemID }, host);
  },
  /** A runtime's sandbox that could not start (064, #253): Continue without it, or Keep stopped. */
  async answerSandbox(this: Store, host: string, agentID: string, carryOn: boolean): Promise<void> {
    await this.act("agents/answerSandbox", { agentID: agentID as UUID, carryOn }, host);
  },
  async setAgentSandbox(this: Store, host: string, agentID: string, choice: SandboxChoice | undefined): Promise<void> {
    await this.act("agents/setSandbox", { agentID: agentID as UUID, ...(choice ? { choice } : {}) }, host);
  },
  async letAgentGoOn(this: Store, host: string, agent: Agent): Promise<void> {
    // Money or tokens, whichever it reached (#838): Agent.goOnRequest.
    const request = goOnRequest(agent, this.costs.value[host]?.limits);
    await this.act("agents/setCeiling", { ...request, agentID: agent.id }, host);
  },
  /** Undo after Archive (#1534): Unarchive what that Archive put away; one it stopped stays stopped. */
  async undoArchive(this: Store): Promise<void> {
    const undo = this.archiveUndo.value;
    if (!undo) return;
    this.archiveUndo.value = null;
    for (const id of undo.agentIDs) await this.perform(undo.host, id, "agents/unarchive");
  },
  /** Offer Undo for an action that went (#4793). */
  offerUndo(this: Store, host: string, undo: ChangeUndo | null): void {
    if (!undo) return;
    this.archiveUndo.value = null;
    this.changeUndo.value = { key: Date.now(), host, line: changeUndoLine(undo.change, undo.title),
      menu: changeUndoMenu(undo.change), inverse: undo.inverse };
  },
  /** Undo (⌘Z) after Unarchive, Rename, the labels, Mute or Later (#4793): the inverse, with no Undo of its own. */
  async undoChange(this: Store): Promise<void> {
    const undo = this.changeUndo.value;
    if (!undo) return;
    this.changeUndo.value = null;
    const { host, inverse } = undo;
    switch (inverse.kind) {
      case "archive": await this.perform(host, inverse.agentID, "agents/archive"); break;
      case "rename": await this.rename(host, inverse.agentID, inverse.title, false); break;
      case "labels": await this.setLabels(host, inverse.agentID, inverse.add, inverse.remove, false); break;
      case "mute": await this.setMuted(host, inverse.agentID, inverse.muted, false); break;
      case "bringBack": await this.undeferRequest(host, inverse.request); break;
    }
  },
  /** Unarchive from a menu (#4793): with Undo, which archives it again. */
  async unarchive(this: Store, host: string, agentID: string): Promise<boolean> {
    const before = this.agent(host, agentID);
    const done = await this.perform(host, agentID, "agents/unarchive");
    if (done && before) this.offerUndo(host, unarchivedUndo(before));
    return done;
  },
  /** Whether the host took it, so a caller can leave the chat only when it did (#586). */
  async perform(this: Store, host: string, agentID: string,
                action: "agents/stop" | "agents/archive" | "agents/unarchive"): Promise<boolean> {
    let done = false;
    const write: AgentWrite = { kind: action === "agents/stop" ? "stop" : action === "agents/archive" ? "archive" : "unarchive" };
    await this.acting(agentID, action, async () => {
      done = await this.optimistic(host, agentID, write, async () =>
        await this.act(action, { agentID: agentID as UUID }, host, write) !== null);
    });
    return done;
  },
  // MARK: Files, changes and live pages (071 US4)

  listFiles(this: Store, host: string, agentID: string, folder: string) {
    return this.link.call("files/list", { agentID: agentID as UUID, folder }, host);
  },
  readFile(this: Store, host: string, agentID: string, path: string, knownStamp?: FileStamp) {
    return this.link.call("files/read", { agentID: agentID as UUID, path, ...(knownStamp ? { knownStamp } : {}) }, host);
  },
  /**
   * Watch the agent's folder that holds `folder`. Counted, so a file open under Files and the
   * tree beside it share one watch, and closing the file does not stop the tree's (#258).
   */
  watchFolder(this: Store, host: string, agentID: string, folder: string): void {
    const root = this.watchRoot(host, agentID, folder);
    const caller = `${host}|${agentID}|${folder}`;
    const held = this.watchedRoot.get(caller) ?? [];
    held.push(root);
    this.watchedRoot.set(caller, held);
    if (this.fileWatches.watch(`${host}|${agentID}|${root}`)) {
      void this.link.call("files/watch", { agentID: agentID as UUID, folder: root }, host).catch(() => {});
    }
  },
  unwatchFolder(this: Store, host: string, agentID: string, folder: string): void {
    const caller = `${host}|${agentID}|${folder}`;
    const held = this.watchedRoot.get(caller);
    const root = held?.pop() ?? this.watchRoot(host, agentID, folder);
    if (held && held.length === 0) this.watchedRoot.delete(caller);
    if (this.fileWatches.unwatch(`${host}|${agentID}|${root}`)) {
      void this.link.call("files/unwatch", { agentID: agentID as UUID, folder: root }, host).catch(() => {});
    }
  },
  /** The folder the host actually watches for this path: the agent's own, or an extra one it was given. */
  watchRoot(this: Store, host: string, agentID: string, folder: string): string {
    const agent = (this.agents.peek()[host] ?? []).find((item) => item.id === agentID);
    return agent ? scopeRoot(agent.cwd, agent.additionalDirectories ?? [], folder) : folder;
  },
  changes(this: Store, host: string, agentID: string) {
    return this.link.call("changes/list", { agentID: agentID as UUID }, host);
  },
  changedFile(this: Store, host: string, agentID: string, path: string, whole = false) {
    return this.link.call("changes/file", { agentID: agentID as UUID, path, whole }, host);
  },
  /** What the person typed on a live page, written to the file as the window writes it. */
  /** The editor's save that checks the file first (#1858): refused when it changed since `base`. */
  async writeArtifactOver(this: Store, host: string, agentID: string, path: string, text: string, base: string): Promise<SaveOutcome> {
    try {
      await this.link.call("artifact/write", { agentID: agentID as UUID, path, text, base }, host);
      return "saved";
    } catch (error) {
      if (error instanceof CallFailed && error.code === Failure.fileChanged) return "changedOnDisk";
      this.say(describe(error));
      return "failed";
    }
  },
  async writeArtifact(this: Store, host: string, agentID: string, path: string, text: string): Promise<boolean> {
    return (await this.act("artifact/write", { agentID: agentID as UUID, path, text }, host)) !== null;
  },
  /**
   * Move to Machine… (#3790): `agentID` goes on on `machine`, in `folder` there, or the folder of
   * its project there when `folder` is empty. Answers once its host has checked the move (#4641),
   * and `move/changed` says how it goes; `arrived` runs once that machine has it. Throws why not.
   */
  async moveToMachine(this: Store, host: string, agentID: string, machine: string, folder: string,
    arrived: (answer: MoveToMachineAnswer) => void): Promise<MoveToMachineAnswer> {
    const there = folder.trim();
    const machineName = this.hosts.value.find((h) => h.id === machine)?.name;
    const answer = await this.link.call("agents/moveToMachine",
      { agentID: agentID as never, machine, ...(machineName ? { machineName } : {}), ...(there ? { folder: there } : {}) }, host);
    // A host from before #4641 answers once that machine has it, and says nothing more.
    if (!this.has(host, Capability.sessionsMoving1)) arrived(answer);
    else this.moveFollows.set(agentID, () => arrived(answer));
    return answer;
  },
  /** Takes a move that stopped off its session's row: once the session is opened (#4641). */
  putAwayMove(this: Store, agentID: string): void {
    if (!this.moves.value[agentID]?.finished) return;
    const { [agentID]: _, ...rest } = this.moves.value;
    this.moves.value = rest;
  },
  /**
   * Report a Problem's issue (#3718), made by `host`: the person's words, the versions and, when
   * asked, its log lines, with tokens and home folders cut out. Sends nothing; throws why not.
   */
  async problemReport(this: Store, host: string, request: ProblemReportRequest): Promise<ProblemReport> {
    return await this.link.call("reports/problem", request, host);
  },
  /**
   * Files into a folder's drop box (#231), one after another, as the window's drop puts them.
   * Answers the names sent; the first that could not go is said, and stops the rest.
   */
  async putInDropbox(this: Store, host: string, folder: string, subfolder: string, files: readonly File[]): Promise<string[]> {
    const sent: string[] = [];
    for (const file of files) {
      const refused = dropboxRefusal(file.name, file.size);
      if (refused) {
        this.say(refused);
        break;
      }
      const bytes = new Uint8Array(await file.arrayBuffer());
      if (await this.act("dropbox/put", dropboxRequest(folder, subfolder, file.name, bytes), host) === null) break;
      sent.push(file.name);
    }
    return sent;
  },
};
