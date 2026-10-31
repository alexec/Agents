// One workflow under a folder's sessions (071 US5; FolderWorkRows.swift): its status mark and its
// name, as the window's and the Remote's rows (#547), and at its end when it last ran, as a session's
// row has its time (#755), or nothing if it never has. Off is its mark and its tooltip. What it is is
// its page's to say (#495).
// Chosen, it opens its page in the chat's place, as the window's list does (#98). Its actions are in
// its right-click / menu-key menu, as a session row's are (#151): Run Now, Approve or Deny on This
// Host while it waits for its OK, Pin (#432) and, under Pinned, Move Up and Down, Turn Off or On
// (#100), Archive or Unarchive (#260).
import { useSignal } from "@preact/signals";
import type { WorkflowSummary } from "../protocol/generated";
import type { Store } from "../model/store";
import { canBeApproved, canBeDenied, isOn, isUnapproved, runsHere, scopeSentence, workflowStatus } from "../model/workflows";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { fromWireDate } from "../protocol/dates";
import { shortAgo } from "../model/activity";
import { isWorkflowMuted, muteLabel, muteMark, mutedHelp, mutedWords, unmuteLabel, workflowMuteHelp } from "../model/mute";
import { Capability } from "../protocol/capabilities.generated";

export function WorkflowRow({ store, host, summary, disabled, chosen, onPick, pinnedAt, place }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; chosen: boolean; onPick: () => void;
  /** The folder's pinned workflows' order, for Move Up and Down: given only under Pinned, with no search. */
  pinnedAt?: string[] | undefined;
  /** Under Pinned at the top of the sidebar, which gathers every folder's: its folder's name (#495). */
  place?: string | undefined;
}) {
  const status = workflowStatus(summary);
  const ran = lastRan(summary);
  const menu = () => workflowMenu(store, host, summary, disabled, onPick, pinnedAt);
  // A user workflow says it is in every folder (#2759), pinned or under Needs You too.
  const pickWords = !isOn(summary) && !summary.isArchived ? `Turned off. Open ${summary.workflow.name}` : `Open ${summary.workflow.name}`;
  const scope = scopeSentence(summary);
  return (
    <div class={`row workflow${chosen ? " chosen" : ""}`} onContextMenu={(e) => openContextMenu(e, menu())}
      onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...holdForMenu(menu)}>
      <button class="pick" aria-current={chosen} onClick={onPick}
        title={scope ? `${pickWords}. ${scope}` : pickWords}>
        <span class={`workflow-mark${status.tinted ? " tinted" : ""}`} role="img" aria-label={status.words} title={status.words}>{status.mark}</span>
        {/* Heavier only while it waits for an OK (#520), as a session's title is while unread. */}
        <span class={`title${summary.awaitingApproval && !summary.isArchived ? " needs-ok" : ""}${place ? " placed" : ""}`}>
          {/* The name gives way before its folder's, which is whole (#587). */}
          {place ? <span class="name">{summary.workflow.name}</span> : summary.workflow.name}
          {place && <span class="place"> {place}</span>}
        </span>
        {/* Its runs send no notifications (#2003), marked as a muted session is. */}
        {isWorkflowMuted(summary) && !summary.isArchived && (
          <span class="started-by muted" role="img" title={mutedHelp} aria-label={mutedWords}>{muteMark}</span>
        )}
        {ran && <time class="when" dateTime={ran.toISOString()} title={ran.toLocaleString()}>{shortAgo(ran)}</time>}
      </button>
    </div>
  );
}

/** When it last ran, for the row's end (#755): none if it never has; a running one's is when this run started. */
export function lastRan(summary: WorkflowSummary): Date | null {
  return summary.lastFiredAt === undefined ? null : fromWireDate(summary.lastFiredAt);
}

/** Run Now, for one that may run: not archived, not waiting for its OK. */
export function RunNow({ store, host, summary, disabled, wide }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; wide?: boolean;
}) {
  const running = useSignal(false);
  if (summary.isArchived || isUnapproved(summary) || !runsHere(summary)) return null;
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

/** What a workflow row's menu offers, in the window's order (FolderWorkRows.swift `WorkflowListRow`). */
export type WorkflowAction = "open" | "unarchive" | "approve" | "deny" | "runNow" | "pin" | "unpin" | "moveUp" | "moveDown"
  | "turnOff" | "turnOn" | "mute" | "unmute" | "archive" | "delete";

export function workflowActions(summary: WorkflowSummary, pinned: boolean, pinnedAt?: string[], canMute = false): WorkflowAction[] {
  const actions: WorkflowAction[] = ["open"];
  if (summary.isArchived) return [...actions, "unarchive", "delete"];
  if (isUnapproved(summary)) {
    if (canBeApproved(summary)) actions.push("approve");
    // Not on this host, without archiving it everywhere (#391).
    if (canBeDenied(summary)) actions.push("deny");
  } else if (runsHere(summary)) {
    actions.push("runNow");
  }
  actions.push(pinned ? "unpin" : "pin");
  // The window orders the pinned by drag; the page has no drag, so its menu moves them.
  if (pinned && pinnedAt) actions.push("moveUp", "moveDown");
  actions.push(isOn(summary) ? "turnOff" : "turnOn");
  // Its runs send no notifications, and still go under Needs You (#2003).
  if (canMute) actions.push(isWorkflowMuted(summary) ? "unmute" : "mute");
  actions.push("archive", "delete");
  return actions;
}

const words: Record<WorkflowAction, string> = {
  open: "Open", unarchive: "Unarchive", approve: "Approve", deny: "Deny on This Machine", runNow: "Run Now",
  pin: "Pin", unpin: "Unpin", moveUp: "Move Up", moveDown: "Move Down", turnOff: "Turn Off", turnOn: "Turn On",
  mute: muteLabel, unmute: unmuteLabel, archive: "Archive", delete: "Delete…",
};

const helps: Partial<Record<WorkflowAction, string>> = {
  pin: "Keep it in Pinned, at the top of its folder", unpin: "Take it out of Pinned",
  turnOff: "None of its triggers run it until it is turned on again; Run Now still does",
  turnOn: "Let its triggers run it again",
  mute: workflowMuteHelp(false), unmute: workflowMuteHelp(true),
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
    unarchive: () => void store.setWorkflowArchived(host, summary, false),
    approve: () => void store.approveWorkflow(host, summary),
    deny: () => void store.denyWorkflow(host, summary),
    runNow: () => void store.runWorkflow(host, summary),
    pin: () => void store.setWorkflowPinned(host, folder, id, true),
    unpin: () => void store.setWorkflowPinned(host, folder, id, false),
    moveUp: () => step(-1),
    moveDown: () => step(1),
    turnOff: () => void store.setWorkflowEnabled(host, summary, false),
    turnOn: () => void store.setWorkflowEnabled(host, summary, true),
    mute: () => void store.setWorkflowMuted(host, summary, true),
    unmute: () => void store.setWorkflowMuted(host, summary, false),
    archive: () => void store.setWorkflowArchived(host, summary, true),
    delete: () => {
      if (confirm(`Delete “${summary.workflow.name}”? Its file is removed from disk.\n\nThe file can be restored from the folder's git history.`)) {
        void store.deleteWorkflow(host, summary);
      }
    },
  };
  const off: Partial<Record<WorkflowAction, boolean>> = {
    approve: !summary.deniedHere && summary.overLimit !== undefined,
    runNow: summary.isRunning,
    moveUp: pinnedAt?.[0] === id,
    moveDown: pinnedAt?.[pinnedAt.length - 1] === id,
  };
  return workflowActions(summary, pinned, pinnedAt, store.has(host, Capability.mute1)).map((action) => ({
    label: words[action], ...(helps[action] ? { help: helps[action] } : {}), run: run[action],
    disabled: action !== "open" && (disabled || !!off[action]),
  }));
}
