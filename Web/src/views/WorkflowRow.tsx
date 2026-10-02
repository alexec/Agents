// One workflow under a project's sessions (071 US5; ProjectWorkRows.swift): its status mark, its
// name, what it is in one line, and Run Now. Chosen, it opens its page in the chat's place, as the
// window's list does (#98); its ··· menu turns it off or on (#100). A workflow waiting for its OK
// is approved on the Mac, which shows what it would run; the page says so instead of offering to
// run it. One turned off still runs now, as the window's does.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { WorkflowSummary } from "../protocol/generated";
import type { Store } from "../model/store";
import { isOn, workflowStatus, workflowSummary } from "../model/workflows";

export function WorkflowRow({ store, host, summary, disabled, chosen, onPick }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; chosen: boolean; onPick: () => void;
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
          <span class="subtitle">{summary.awaitingApproval ? "Waiting for your OK on the Mac" : workflowSummary(summary.workflow, name)}</span>
        </span>
      </button>
      <RunNow store={store} host={host} summary={summary} disabled={disabled} />
      {!summary.isArchived && <WorkflowMenu store={store} host={host} summary={summary} disabled={disabled} />}
    </div>
  );
}

/** Run Now, for one that may run: not archived, not waiting for its OK. */
export function RunNow({ store, host, summary, disabled, wide }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean; wide?: boolean;
}) {
  const running = useSignal(false);
  if (summary.isArchived || summary.awaitingApproval) return null;
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

/** The row's menu: Turn Off or Turn On (#100), as the window's row and the Remote's have it. */
function WorkflowMenu({ store, host, summary, disabled }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean;
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
  return (
    <span class="menu-anchor workflow-menu" ref={anchor}>
      <button class="icon" aria-label={`More for ${summary.workflow.name}`} title="More" aria-haspopup="menu"
        aria-expanded={open.value} disabled={disabled} onClick={() => (open.value = !open.value)}>···</button>
      {open.value && (
        <div class="popover right" role="menu">
          <button role="menuitem" title={on ? "None of its triggers run it until it is turned on again; Run Now still does"
            : "Let its triggers run it again"}
            onClick={() => { open.value = false; void store.setWorkflowEnabled(host, summary, !on); }}>
            {on ? "Turn Off" : "Turn On"}
          </button>
        </div>
      )}
    </span>
  );
}
