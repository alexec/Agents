// Part of the Store (#5384): agentActions.
import type { Agent, FolderSummary, Methods, FoldersFindRequest, FoundFolder } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { describe } from "../errors";
import { log } from "../../log";
import { folderPath as agentFolderPath } from "../groups";
import { type AgentWrite, failureLine, writeFailure } from "../pendingWrites";
import type { Store } from "../store";

export const agentActionsMethods = {
  /**
   * Calls `method`, and on failure says why in `problem` and answers null. With `write` (a change,
   * or the verb of one), the line says what failed first: "Could not archive — …" (#4786, #4814).
   */
  async act<M extends keyof Methods>(this: Store, method: M, params: Methods[M]["params"], host: string,
                                     write?: AgentWrite | string): Promise<Methods[M]["result"] | null> {
    try {
      return await this.link.call(method, params, host);
    } catch (error) {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      const why = describe(error);
      this.say(write === undefined ? why : typeof write === "string" ? failureLine(write, why) : writeFailure(write, why));
      return null;
    }
  },
  /**
   * A change drawn on the agent at once, and settled by `send`: kept on screen when it went,
   * and the host's record put back when it did not (#4786).
   */
  async optimistic(this: Store, host: string, agentID: string, write: AgentWrite, send: () => Promise<boolean>): Promise<boolean> {
    const shown = (this.agents.peek()[host] ?? []).find((a) => a.id === agentID);
    const begun = shown ? this.pending.begin(host, shown, write) : null;
    if (begun) this.showAgent(host, begun.agent);
    const sent = await send();
    const back = begun ? this.pending.settle(host, agentID, begun.id, !sent) : null;
    if (back) this.showAgent(host, back);
    return sent;
  },
  /** One agent as this page now shows it, in its place. */
  showAgent(this: Store, host: string, agent: Agent): void {
    const held = this.agents.peek()[host] ?? [];
    if (!held.some((a) => a.id === agent.id)) return;
    this.setAgents(host, held.map((a) => (a.id === agent.id ? agent : a)), [agentFolderPath(agent)]);
  },
  /**
   * A folder on `host` as a folder (#115), as the window's Add Folder… does. Answers the
   * folder, or null with `problem` saying why. With `project`, it joins the project picked in
   * the Add Folder sheet (#2671); with none, a folder that names no project gets one of its own.
   */
  async addFolder(this: Store, host: string, folder: string, project?: string): Promise<FolderSummary | null> {
    const params = project === undefined ? { folder: folder as never } : { folder: folder as never, project };
    const summary = await this.act("folders/add", params, host);
    if (summary) this.upsertFolder(summary, host);
    return summary;
  },
  /** Where Choose Folders… looks on a machine (#4122), as the window's: the control plane's auto-detect paths, none with it off. */
  async folderPaths(this: Store): Promise<string[]> {
    const status = await this.link.call("control/status", {}).catch(() => null);
    const detection = status?.folderDetection;
    return detection?.enabled ? detection.paths : [];
  },
  /** The git repositories under `paths` on `host`, or the `folders` typed, as they stand there (#4122). It throws when the host can't be asked. */
  findFolders(this: Store, host: string, request: FoldersFindRequest): Promise<FoundFolder[]> {
    return this.link.call("folders/find", request, host);
  },
  /** Choose Folders…' Add (#4122): each folder added on `host`; answers why each that failed was not, by folder. */
  async addFolders(this: Store, host: string, folders: readonly string[]): Promise<Record<string, string>> {
    const failed: Record<string, string> = {};
    for (const folder of folders) {
      try {
        this.upsertFolder(await this.link.call("folders/add", { folder: folder as never }, host), host);
      } catch (error) {
        failed[folder] = describe(error);
      }
    }
    return failed;
  },
  /**
   * Clones `url` into the host's home folder and adds it (027, #115). Answers once the clone
   * has finished; the row meanwhile comes from `clone/changed`.
   */
  async cloneFolder(this: Store, host: string, url: string): Promise<FolderSummary | null> {
    const summary = await this.act("folders/clone", { url }, host);
    if (summary) this.upsertFolder(summary, host);
    return summary;
  },
  /**
   * A folder put away (#668), as the window's Archive does: it moves to Archived folders with
   * its sessions. A refusal names the sessions to stop first.
   */
  async archiveFolder(this: Store, host: string, folder: string): Promise<FolderSummary | null> {
    const summary = await this.act("folders/archive", { folder: folder as never }, host);
    if (summary) this.upsertFolder(summary, host);
    return summary;
  },
  /**
   * An archived folder unarchived (#343), as the window's Unarchive does: a folder again,
   * with its new-session form open.
   */
  async unarchiveFolder(this: Store, host: string, folder: string): Promise<FolderSummary | null> {
    const summary = await this.act("folders/unarchive", { folder: folder as never }, host);
    if (summary) this.upsertFolder(summary, host);
    return summary;
  },
  /**
   * An archived folder deleted (#677), asked first: every session in it and its record; its
   * folder stays. A refusal says which sessions hold it.
   */
  async deleteFolder(this: Store, host: string, folder: string): Promise<boolean> {
    if (await this.act("folders/delete", { folder: folder as never }, host) === null) return false;
    this.removeFolder(folder, host);
    return true;
  },
};
