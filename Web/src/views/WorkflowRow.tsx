// One workflow under a project's sessions (071 US5; ProjectWorkRows.swift): its status mark, its
// name, what it is in one line, and Run Now. A workflow waiting for its OK is approved on the
// Mac, which shows what it would run; the page says so instead of offering to run it. One turned
// off still runs now, as the window's does.
import { useSignal } from "@preact/signals";
import type { WorkflowSummary } from "../protocol/generated";
import type { Store } from "../model/store";
import { workflowStatus, workflowSummary } from "../model/workflows";

export function WorkflowRow({ store, host, summary, disabled }: {
  store: Store; host: string; summary: WorkflowSummary; disabled: boolean;
}) {
  const running = useSignal(false);
  const status = workflowStatus(summary);
  const name = (id: string) => (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === id)?.runtime.name;
  const canRun = !summary.isArchived && !summary.awaitingApproval;
  return (
    <div class="row workflow">
      <span class={`workflow-mark${status.tinted ? " tinted" : ""}`} role="img" aria-label={status.words} title={status.words}>{status.mark}</span>
      <span class="body">
        <span class="title">
          {summary.workflow.name}
          {/* Marked where it stands, rather than moved (#100): off is not put away. */}
          {!summary.isEnabled && !summary.isArchived && <span class="faint"> · Off</span>}
        </span>
        <span class="subtitle">{summary.awaitingApproval ? "Waiting for your OK on the Mac" : workflowSummary(summary.workflow, name)}</span>
      </span>
      {canRun && (
        <button class="run-now" disabled={disabled || running.value || summary.isRunning}
          title={`Run ${summary.workflow.name} now`} aria-label={`Run ${summary.workflow.name} now`}
          onClick={async () => {
            running.value = true;
            await store.runWorkflow(host, summary);
            running.value = false;
          }}>{running.value || summary.isRunning ? "Running…" : "Run Now"}</button>
      )}
    </div>
  );
}
