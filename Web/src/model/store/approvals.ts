// Part of the Store (#5384): approvals.
import { answerElsewhere, approveSecretUse, type SecretUseAction, secretUseApprovalParams, secretUseSigns } from "../secretUse";
import type { Agent, FolderSummary, GuardedChange, GuardedChangeReading, Approval, ApprovalAction, RequestSecretUse, LockDelivery } from "../../protocol/generated";
import { signRequest } from "../../wire/lockChannel";
import { describe } from "../errors";
import { folderKey, folderPath as agentFolderPath } from "../groups";
import { approvalFailure, approvalID } from "../approvals";
import type { Store } from "../store";

export const approvalsMethods = {
  /**
   * The changes to a folder's own files waiting for Keep or Undo (#531): those asked in `session`,
   * the agent that made them, or with no session, those asked of the folder `folder` on its page.
   */
  guardedChanges(this: Store, host: string, where: { session: string } | { folder: string }): { folder: string; change: GuardedChange }[] {
    const found: { folder: string; change: GuardedChange }[] = [];
    for (const summary of this.folders.value[host] ?? []) {
      if ("folder" in where && folderKey(summary.folder.folder) !== folderKey(where.folder)) continue;
      for (const change of summary.guardedChanges ?? []) {
        const askedIn = change.askedIn ?? null;
        if ("session" in where ? askedIn === where.session : askedIn === null) {
          found.push({ folder: summary.folder.folder, change });
        }
      }
    }
    return found;
  },
  /** What a guarded file was and is (#502), for the person deciding. */
  async readGuardedChange(this: Store, host: string, folder: string, change: GuardedChange): Promise<GuardedChangeReading | null> {
    return await this.act("folders/readGuardedChange", { folder: folder as never, path: change.path }, host);
  },
  /** Keep (the change is used from now on) or Undo (the approved copy goes back), of the file as it was shown. */
  async settleGuardedChange(this: Store, host: string, folder: string, reading: GuardedChangeReading, keep: boolean): Promise<void> {
    const params = { folder: folder as never, path: reading.path, ...(reading.digest !== undefined ? { digest: reading.digest } : {}) };
    const summary = await this.act(keep ? "folders/keepGuardedChange" : "folders/undoGuardedChange", params, host);
    if (summary) this.upsertFolder(summary, host);
  },
  /**
   * What a waiting item is (#773): a file's diff against the approved copy, an MCP server's entry,
   * a plugin's files. Throws a refusal, which the sheet says in its place.
   */
  readApproval(this: Store, host: string, folder: string, approval: Approval): Promise<GuardedChangeReading> {
    return this.link.call("approvals/read", { folder: folder as never, kind: approval.kind, key: approval.key }, host);
  },
  /**
   * Approve, Deny or Request Changes of a waiting item (#773), of the version read (`digest`), so a
   * change since is refused and not approved. Throws a refusal, which the sheet says in its place,
   * staying open; answered, the folder's list is the host's again.
   */
  async answerApproval(this: Store, host: string, folder: string, approval: Approval, action: ApprovalAction,
    digest: string | undefined, note?: string): Promise<FolderSummary> {
    let failure: unknown;
    // Out of the list at once, and back if the answer did not go (#4814).
    const summary = await this.answeringApproval(host, folder, approvalID(approval), async () => {
      try {
        return await this.link.call("approvals/answer", {
          folder: folder as never, kind: approval.kind, key: approval.key, action,
          ...(digest !== undefined ? { digest } : {}), ...(note !== undefined ? { note } : {}),
        }, host);
      } catch (error) {
        failure = error;
        return null;
      }
    });
    if (!summary) throw failure;
    this.upsertFolder(summary, host);
    return summary;
  },
  /**
   * Approve or Deny from a row's menu, of the version the row shows (#4814): the row goes at once,
   * and a refusal comes back as "Could not approve — <why>", with the row.
   */
  async settleApproval(this: Store, host: string, folder: string, approval: Approval, action: ApprovalAction): Promise<void> {
    await this.answerApproval(host, folder, approval, action, approval.digest)
      .catch((error: unknown) => this.say(approvalFailure(action, describe(error))));
  },
  /**
   * A person's answer to a secret's use (#4017), from its Needs you row: to the host that asked.
   * From the row's menu, so a refusal is said in `problem`; `requests/changed` takes the row away.
   */
  async answerSecretUse(this: Store, host: string, request: string, action: SecretUseAction, use?: RequestSecretUse): Promise<void> {
    let approval: LockDelivery | undefined;
    // A Linux machine opens the value only for an answer this page signed with its lock key (#4149).
    if (use && secretUseSigns(use, action)) {
      const source = await this.machineLock.signer();
      if (!source) {
        this.say(`Not sent — this machine opens the secret only for an answer your device signs, and this page is not in your lock. ${answerElsewhere}.`);
        return;
      }
      const params = secretUseApprovalParams(request, use, action);
      approval = { method: approveSecretUse, params, lock: await signRequest(source.signer, host, approveSecretUse, params) };
    }
    await this.act("requests/answer", { id: request as never, answer: { secretUse: approval ? { action, approval } : { action } } }, host);
  },
  /**
   * Keep Session (#773): an agent's request to archive its session denied, so the session stays
   * where it is. From the row's menu, so a refusal is said in `problem`.
   */
  async keepSession(this: Store, host: string, agent: Agent): Promise<void> {
    const folder = agentFolderPath(agent);
    const listed = (this.folders.value[host] ?? []).find((p) => folderKey(p.folder.folder) === folder)?.folder.folder;
    const summary = await this.answeringApproval(host, listed ?? folder, `archive:${agent.id}`, () =>
      this.act("approvals/answer",
        { folder: (listed ?? folder) as never, kind: "archive", key: agent.id, action: "deny" }, host, "keep the session"));
    if (summary) this.upsertFolder(summary, host);
  },
  /**
   * Dismiss a failed workflow (#989): out of Needs You until it fails again, kept on the workflow's
   * record on its host. From the row's menu, so a refusal is said in `problem`.
   */
  async dismissWorkflowFailure(this: Store, host: string, folder: string, approval: Approval): Promise<void> {
    const summary = await this.answeringApproval(host, folder, approvalID(approval), () =>
      this.act("approvals/answer", {
        folder: folder as never, kind: approval.kind, key: approval.key, action: "dismiss",
        ...(approval.digest !== undefined ? { digest: approval.digest } : {}),
      }, host, "dismiss"));
    if (summary) this.upsertFolder(summary, host);
  },
};
