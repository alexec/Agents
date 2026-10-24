// One thing waiting for the person's OK in Needs You (#773): an MCP server, a workflow, a plugin or a
// guarded file, as the window's and the Remote's ApprovalRowLabel (Shared/UI/ApprovalViews.swift).
// The row is drawn as a session's is (#587): the mark, the title with its folder, the time and one
// grey line, with the same orange shield for every kind. Opened, its Review page (Review.tsx, #1472)
// says what it is, shows the lines being approved, and offers the answers its host does.
import type { Approval as ApprovalItem, ApprovalAction } from "../protocol/generated";
import type { Store } from "../model/store";
import { actionWord, approvalID, approvalLine } from "../model/approvals";
import { shortAgo } from "../model/activity";
import { describe } from "../model/errors";
import { fromWireDate } from "../protocol/dates";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { go } from "../route";

/** The mark every approval row wears: a shield with a tick, in the attention tint. */
export function ApprovalMark() {
  return (
    <span class="sidebar-mark approval" aria-hidden="true">
      <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4"
        stroke-linejoin="round" stroke-linecap="round">
        <path d="M8 1.75 2.75 3.75v4c0 3.1 2.2 5.3 5.25 6.5 3.05-1.2 5.25-3.4 5.25-6.5v-4z" />
        <path d="m5.6 8.1 1.7 1.7 3.2-3.4" />
      </svg>
    </span>
  );
}

/** A failed workflow's mark (#989): the triangle its own row wears on its folder's page, in the attention tint. */
export function FailedMark() {
  return (
    <span class="sidebar-mark approval" aria-hidden="true">
      <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4"
        stroke-linejoin="round" stroke-linecap="round">
        <path d="M8 2 1.75 13.25h12.5z" />
        <path d="M8 6.5v3.25M8 11.6v.01" />
      </svg>
    </span>
  );
}

/**
 * A workflow that has stopped working, under Needs You (#989), as the window's FailedWorkflowRow:
 * the failure in its grey line. A press opens the run's agent, which Needs You does not list again,
 * or the workflow when no agent ran; Dismiss, in its menu, takes it out until it fails again.
 */
export function FailedWorkflowRow({ store, host, folder, approval, place, down, chosen }: {
  store: Store; host: string; folder: string; approval: ApprovalItem; place: string; down: boolean; chosen: boolean;
}) {
  const since = approval.since === undefined ? undefined : fromWireDate(approval.since);
  const agentID = approval.agentID as string | undefined;
  const open = () => go(agentID ? { host, folder: folder, session: agentID } : { host, folder: folder, workflow: approval.key });
  const menu = (): MenuItem[] => [
    { label: "Open", run: open },
    ...(agentID ? [{ label: "Open Workflow", run: () => go({ host, folder: folder, workflow: approval.key }) }] : []),
    ...(approval.actions.includes("dismiss") ? [{
      label: actionWord(approval.kind, "dismiss"), disabled: down, help: "Out of Needs You until it fails again",
      run: () => void store.dismissWorkflowFailure(host, folder, approval),
    }] : []),
  ];
  return (
    <div class="nav-item">
      <button class={`row session approval${chosen ? " chosen" : ""}`} aria-current={chosen} aria-description="stopped working"
        onClick={open} onContextMenu={(e) => openContextMenu(e, menu())}
        onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...holdForMenu(menu)}>
        <FailedMark />
        <span class="body">
          <span class="title placed">
            <span class="name">{approval.title}</span>
            <span class="place"> {place}</span>
          </span>
          <span class="subtitle">{approvalLine(approval)}</span>
        </span>
        {since && <time class="when" dateTime={since.toISOString()} title={since.toLocaleString()}>{shortAgo(since)}</time>}
      </button>
    </div>
  );
}

/**
 * Its row under Needs You, with its folder's name after the title, as the group's session rows
 * have theirs. A press, Enter or Space opens its Review page in the chat's place (#1472); its menu
 * answers at once, of the version the row was drawn from.
 */
export function ApprovalRow({ store, host, folder, approval, place, down, chosen }: {
  store: Store; host: string; folder: string; approval: ApprovalItem; place: string; down: boolean; chosen: boolean;
}) {
  const since = approval.since === undefined ? undefined : fromWireDate(approval.since);
  const open = () => go({ host, folder: folder, review: approvalID(approval) });
  const answer = (action: ApprovalAction) => () => void store.answerApproval(host, folder, approval, action, approval.digest)
    .catch((error) => store.say(describe(error)));
  const menu = (): MenuItem[] => [
    { label: "Review…", run: open },
    ...(approval.actions.includes("approve") ? [{ label: actionWord(approval.kind, "approve"), disabled: down, run: answer("approve") }] : []),
    ...(approval.actions.includes("deny") ? [{ label: actionWord(approval.kind, "deny"), disabled: down, run: answer("deny") }] : []),
    ...(approval.actions.includes("requestChanges") ? [{ label: `${actionWord(approval.kind, "requestChanges")}…`, run: open }] : []),
  ];
  return (
    <div class="nav-item">
      <button class={`row session approval${chosen ? " chosen" : ""}`} aria-current={chosen} aria-description="waiting for your approval"
        onClick={open} onContextMenu={(e) => openContextMenu(e, menu())}
        onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...holdForMenu(menu)}>
        <ApprovalMark />
        <span class="body">
          <span class="title placed">
            <span class="name">{approval.title}</span>
            <span class="place"> {place}</span>
          </span>
          <span class="subtitle">{approvalLine(approval)}</span>
        </span>
        {since && <time class="when" dateTime={since.toISOString()} title={since.toLocaleString()}>{shortAgo(since)}</time>}
      </button>
    </div>
  );
}
