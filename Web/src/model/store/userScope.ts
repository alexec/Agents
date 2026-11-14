// Part of the Store (#5384): userScope.
import type { WorkflowSummary, OutsideAccounts } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { describe } from "../errors";
import { log } from "../../log";
import { folderKey } from "../groups";
import type { Store } from "../store";

export const userScopeMethods = {
  async loadUserWorkflows(this: Store, host: string): Promise<void> {
    const listed = await this.link.call("workflows/list", { scope: "user" }, host).catch(() => null);
    if (!listed) return;
    const byFolder = new Map<string, WorkflowSummary[]>();
    for (const workflow of listed) {
      const key = folderKey(workflow.workflow.folder);
      byFolder.set(key, [...(byFolder.get(key) ?? []), workflow]);
    }
    for (const [folder, workflows] of byFolder) {
      const key = `${host}|${folder}`;
      this.workflowsLoaded.add(key);
      this.writeWorkflows(key, workflows);
    }
  },
  async writeUserWorkflow(this: Store, host: string, workflowID: string, content: string): Promise<string | null> {
    try {
      const updated = await this.link.call("workflows/write", { workflowID, content }, host);
      this.upsertWorkflow(updated, host);
      return null;
    } catch (error) {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      return describe(error);
    }
  },
  /** The files, or why they could not be read (#3368). */
  async agentConfigEditorFiles(this: Store, host: string, folder: string | undefined, kind: "skills" | "personas" | "workflows") {
    return this.link.call("agentConfig/editorFiles", { folder: folder as never, kind }, host)
      .catch((error: unknown) => ({ problem: describe(error) }));
  },
  async saveAgentConfigEditorFile(this: Store, host: string, folder: string | undefined,
    kind: "skills" | "personas" | "workflows", path: string, content: string, remove: boolean): Promise<string | null> {
    try {
      await this.link.call("agentConfig/editorSave", { folder: folder as never, kind, path, content, delete: remove }, host);
      if (kind === "workflows" && folder === undefined) await this.loadUserWorkflows(host);
      if (kind === "workflows" && folder !== undefined) await this.loadWorkflows(host, folder);
      return null;
    } catch (error) { return describe(error); }
  },
  /** Reads Status ▸ Secrets and Status ▸ Accounts' lists into userScopeStatus (#4161). */
  async loadUserScopeStatus(this: Store) {
    try {
      const [names, settings] = await Promise.all([this.link.call("user/secretNames", {}), this.link.call("user/settings", {})]);
      this.userScopeStatus.value = { secrets: names.secrets, accounts: (settings.accounts as OutsideAccounts | undefined)?.accounts ?? [] };
    } catch {
      // A control plane with no user scope: the pages say there is nothing yet.
    }
  },
};
