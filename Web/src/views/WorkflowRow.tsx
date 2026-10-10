// One workflow under a project's sessions (071 US5; ProjectWorkRows.swift): its status mark, its
// name and Off, as the window's and the Remote's rows (#547); what it is is its page's to say (#495).
// Chosen, it opens its page in the chat's place, as the window's list does (#98). Its actions are in
// its right-click / menu-key menu, as a session row's are (#151): Run Now, Approve or Deny on This
// Host while it waits for its OK, Pin (#432) and, under Pinned, Move Up and Down, Turn Off or On
// (#100), Archive or Bring Back (#260).
import { useSignal } from "@preact/signals";
import type { WorkflowSummary } from "../protocol/generated";
import type { Store } from "../model/store";
import { canBeApproved, canBeDenied, isOn, isUnapproved, workflowStatus } from "../model/workflows";
import { isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";

export function WorkflowRow({ store, host, summary, disabled, chosen, onPick, pinnedAt, place }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; chosen: boolean; onPick: () => void;
  /** The project's pinned workflows' order, for Move Up and Down: given only under Pinned, with no search. */
  pinnedAt?: string[] | undefined;
  /** Under Pinned at the top of the sidebar, which gathers every project's: its project's name (#495). */
  place?: string | undefined;
}) {
  const status = workflowStatus(summary);
  const menu = () => workflowMenu(store, host, summary, disabled, onPick, pinnedAt);
  return (
    <div class={`row workflow${chosen ? " chosen" : ""}`} onContextMenu={(e) => openContextMenu(e, menu())}
      onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }}>
      <button class="pick" aria-current={chosen} onClick={onPick} title={`Open ${summary.workflow.name}`}>
        <span class={`workflow-mark${status.tinted ? " tinted" : ""}`} role="img" aria-label={status.words} title={status.words}>{status.mark}</span>
        {/* Heavier only while it waits for an OK (#520), as a session's title is while unread. */}
        <span class={`title${summary.awaitingApproval && !summary.isArchived ? " needs-ok" : ""}`}>
          {summary.workflow.name}
          {/* Marked where it stands, rather than moved (#100): off is not put away. */}
          {!isOn(summary) && !summary.isArchived && <span class="faint"> · Off</span>}
          {place && <span class="place"> {place}</span>}
        </span>
      </button>
    </div>
  );
}

/** Run Now, for one that may run: not archived, not waiting for its OK. */
export function RunNow({ store, host, summary, disabled, wide }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; wide?: boolean;
}) {
  const running = useSignal(false);
  if (summary.isArchived || isUnapproved(summary)) return null;
  return (
    <button class={`run-now${wide ? " prominent" : ""}`} disabled={disabled || running.value || summary.isRunning}
      title={`Run ${summary.workflow.name} now`} aria-label={`Run ${summary.workflow.name} now`}
      onClick={async () => {
        running.value = true;
        await store.runWorkflow(host, summary);
        running.value = false;
      }}>{running.value || summary.isRunning ? "Running…" : "Run Now"}</button>
  );
}

/** What a workflow row's menu offers, in the window's order (ProjectWorkRows.swift `WorkflowListRow`). */
export type WorkflowAction = "open" | "bringBack" | "approve" | "deny" | "runNow" | "pin" | "unpin" | "moveUp" | "moveDown"
  | "turnOff" | "turnOn" | "archive";

export function workflowActions(summary: WorkflowSummary, pinned: boolean, pinnedAt?: string[]): WorkflowAction[] {
  const actions: WorkflowAction[] = ["open"];
  if (summary.isArchived) return [...actions, "bringBack"];
  if (isUnapproved(summary)) {
    if (canBeApproved(summary)) actions.push("approve");
    // Not on this host, without archiving it everywhere (#391).
    if (canBeDenied(summary)) actions.push("deny");
  } else {
    actions.push("runNow");
  }
  actions.push(pinned ? "unpin" : "pin");
  // The window orders the pinned by drag; the page has no drag, so its menu moves them.
  if (pinned && pinnedAt) actions.push("moveUp", "moveDown");
  actions.push(isOn(summary) ? "turnOff" : "turnOn", "archive");
  return actions;
}

const words: Record<WorkflowAction, string> = {
  open: "Open", bringBack: "Bring Back", approve: "Approve", deny: "Deny on This Host", runNow: "Run Now",
  pin: "Pin", unpin: "Unpin", moveUp: "Move Up", moveDown: "Move Down", turnOff: "Turn Off", turnOn: "Turn On",
  archive: "Archive",
};

const helps: Partial<Record<WorkflowAction, string>> = {
  pin: "Keep it in Pinned, at the top of its project", unpin: "Take it out of Pinned",
  turnOff: "None of its triggers run it until it is turned on again; Run Now still does",
  turnOn: "Let its triggers run it again",
};

function workflowMenu(store: Store, host: string, summary: WorkflowSummary, disabled: boolean, onPick: () => void,
  pinnedAt?: string[]): MenuItem[] {
  const id = summary.workflow.workflowID;
  const folder = summary.workflow.folder as unknown as string;
  const pinned = store.workflowPinsIn(host, folder).includes(id);
  const step = (by: number) => {
    const ids = [...(pinnedAt ?? [])];
    const at = ids.indexOf(id);
    if (at < 0 || at + by < 0 || at + by >= ids.length) return;
    [ids[at], ids[at + by]] = [ids[at + by]!, ids[at]!];
    void store.arrangeWorkflowPins(host, folder, ids);
  };
  const run: Record<WorkflowAction, () => void> = {
    open: onPick,
    bringBack: () => void store.setWorkflowArchived(host, summary, false),
    approve: () => void store.approveWorkflow(host, summary),
    deny: () => void store.denyWorkflow(host, summary),
    runNow: () => void store.runWorkflow(host, summary),
    pin: () => void store.setWorkflowPinned(host, folder, id, true),
    unpin: () => void store.setWorkflowPinned(host, folder, id, false),
    moveUp: () => step(-1),
    moveDown: () => step(1),
    turnOff: () => void store.setWorkflowEnabled(host, summary, false),
    turnOn: () => void store.setWorkflowEnabled(host, summary, true),
    archive: () => void store.setWorkflowArchived(host, summary, true),
  };
  const off: Partial<Record<WorkflowAction, boolean>> = {
    approve: !summary.deniedHere && summary.overLimit !== undefined,
    runNow: summary.isRunning,
    moveUp: pinnedAt?.[0] === id,
    moveDown: pinnedAt?.[pinnedAt.length - 1] === id,
  };
  return workflowActions(summary, pinned, pinnedAt).map((action) => ({
    label: words[action], ...(helps[action] ? { help: helps[action] } : {}), run: run[action],
    disabled: action !== "open" && (disabled || !!off[action]),
  }));
}
