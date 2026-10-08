// One workflow under a project's sessions (071 US5; ProjectWorkRows.swift): its status mark, its
// name, what it is in one line, and Run Now. Chosen, it opens its page in the chat's place, as the
// window's list does (#98); its ··· menu turns it off or on (#100). A workflow waiting for its OK
// can be approved, archived or brought back in its menu, as in the window (#260).
// offering to run it. One turned off still runs now, as the window's does. Its menu pins it to the
// top of its project (#432), and a pinned one's moves it among the pinned.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { WorkflowSummary } from "../protocol/generated";
import type { Store } from "../model/store";
import { canBeApproved, canBeDenied, isOn, isUnapproved, workflowStatus, workflowSummary } from "../model/workflows";

export function WorkflowRow({ store, host, summary, disabled, chosen, onPick, pinnedAt }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; chosen: boolean; onPick: () => void;
  /** The project's pinned workflows' order, for Move Up and Down: given only under Pinned, with no search. */
  pinnedAt?: string[] | undefined;
}) {
  const status = workflowStatus(summary);
  const name = (id: string) => (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === id)?.runtime.name;
  return (
    <div class={`row workflow${chosen ? " chosen" : ""}`}>
      <button class="pick" aria-current={chosen} onClick={onPick} title={`Open ${summary.workflow.name}`}>
        <span class={`workflow-mark${status.tinted ? " tinted" : ""}`} role="img" aria-label={status.words} title={status.words}>{status.mark}</span>
        <span class="body">
          <span class="title">
            {summary.workflow.name}
            {/* Marked where it stands, rather than moved (#100): off is not put away. */}
            {!isOn(summary) && !summary.isArchived && <span class="faint"> · Off</span>}
          </span>
          <span class="subtitle">{summary.awaitingApproval ? "Waiting for your OK"
            : summary.deniedHere ? "Denied on this host" : workflowSummary(summary.workflow, name)}</span>
        </span>
      </button>
      <RunNow store={store} host={host} summary={summary} disabled={disabled} />
      <WorkflowMenu store={store} host={host} summary={summary} disabled={disabled} pinnedAt={pinnedAt} />
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

/** The row's workflow actions, as the window's row menu has them. */
function WorkflowMenu({ store, host, summary, disabled, pinnedAt }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; pinnedAt?: string[] | undefined;
}) {
  const open = useSignal(false);
  const anchor = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open.value) return;
    const close = (e: Event) => { if (!anchor.current?.contains(e.target as Node)) open.value = false; };
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") open.value = false; };
    addEventListener("pointerdown", close);
    addEventListener("keydown", escape);
    return () => { removeEventListener("pointerdown", close); removeEventListener("keydown", escape); };
  }, [open.value]);
  const on = isOn(summary);
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
  return (
    <span class="menu-anchor workflow-menu" ref={anchor}>
      <button class="icon" aria-label={`More for ${summary.workflow.name}`} title="More" aria-haspopup="menu"
        aria-expanded={open.value} disabled={disabled} onClick={() => (open.value = !open.value)}>···</button>
      {open.value && (
        <div class="popover right" role="menu">
          {summary.isArchived ? (
            <button role="menuitem" disabled={disabled} onClick={() => { open.value = false; void store.setWorkflowArchived(host, summary, false); }}>Bring Back</button>
          ) : <>
            {canBeApproved(summary) && <button role="menuitem" disabled={disabled || (!summary.deniedHere && summary.overLimit !== undefined)}
              onClick={() => { open.value = false; void store.approveWorkflow(host, summary); }}>Approve</button>}
            {/* Not on this host, without archiving it everywhere (#391). */}
            {canBeDenied(summary) && <button role="menuitem" disabled={disabled}
              onClick={() => { open.value = false; void store.denyWorkflow(host, summary); }}>Deny on This Host</button>}
            <button role="menuitem" disabled={disabled} title={pinned ? "Take it out of Pinned" : "Keep it in Pinned, at the top of its project"}
              onClick={() => { open.value = false; void store.setWorkflowPinned(host, folder, id, !pinned); }}>
              {pinned ? "Unpin" : "Pin"}
            </button>
            {pinned && pinnedAt && <>
              <button role="menuitem" disabled={disabled || pinnedAt[0] === id}
                onClick={() => { open.value = false; step(-1); }}>Move Up</button>
              <button role="menuitem" disabled={disabled || pinnedAt[pinnedAt.length - 1] === id}
                onClick={() => { open.value = false; step(1); }}>Move Down</button>
            </>}
            <button role="menuitem" disabled={disabled} title={on ? "None of its triggers run it until it is turned on again; Run Now still does"
              : "Let its triggers run it again"}
              onClick={() => { open.value = false; void store.setWorkflowEnabled(host, summary, !on); }}>
              {on ? "Turn Off" : "Turn On"}
            </button>
            <button role="menuitem" disabled={disabled} onClick={() => { open.value = false; void store.setWorkflowArchived(host, summary, true); }}>Archive</button>
          </>}
        </div>
      )}
    </span>
  );
}
