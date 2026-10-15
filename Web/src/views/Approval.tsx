// One thing waiting for the person's OK in Needs You (#773): an MCP server, a workflow, a plugin or a
// guarded file, as the window's and the Remote's ApprovalRowLabel and ApprovalSheet
// (Shared/UI/ApprovalViews.swift). The row is drawn as a session's is (#587): the mark, the title
// with its project, the time and one grey line, with the same orange shield for every kind. Opened,
// a sheet says what it is, shows the lines being approved, and offers the answers its host does.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Approval as ApprovalItem, ApprovalAction, GuardedChangeReading } from "../protocol/generated";
import type { Store } from "../model/store";
import { actionWord, approvalLine, explanations, kindWords, notePlaceholder, sendNoteLabel } from "../model/approvals";
import { shortAgo } from "../model/activity";
import { describe } from "../model/errors";
import { fromWireDate } from "../protocol/dates";
import { Lines } from "./Changes";
import { readingLines } from "./GuardedChange";
import { Modal } from "./Modal";
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

/** A failed workflow's mark (#989): the triangle its own row wears on its project's page, in the attention tint. */
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
  const open = () => go(agentID ? { host, project: folder, session: agentID } : { host, project: folder, workflow: approval.key });
  const menu = (): MenuItem[] => [
    { label: "Open", run: open },
    ...(agentID ? [{ label: "Open Workflow", run: () => go({ host, project: folder, workflow: approval.key }) }] : []),
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
 * Its row under Needs You, with its project's name after the title, as the group's session rows
 * have theirs. A press, Enter or Space opens the sheet; the arrow keys only land on it.
 */
export function ApprovalRow({ store, host, folder, approval, place, down }: {
  store: Store; host: string; folder: string; approval: ApprovalItem; place: string; down: boolean;
}) {
  const open = useSignal(false);
  const since = approval.since === undefined ? undefined : fromWireDate(approval.since);
  return (
    <div class="nav-item">
      <button class="row session approval" aria-haspopup="dialog" aria-description="waiting for your approval"
        onClick={() => (open.value = true)}>
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
      {open.value && (
        <ApprovalSheet store={store} host={host} folder={folder} approval={approval} place={place} down={down}
          close={() => (open.value = false)} />
      )}
    </div>
  );
}

/**
 * What a waiting item is, and the choice: the lines being approved (a file's diff against the
 * approved copy, an MCP server's entry, a plugin's files), what Approve and Deny do, then the
 * answers the host offers for it. Request Changes opens a note sent to the agent that made the
 * change. A refusal is said here and the sheet stays; answered, it closes.
 */
export function ApprovalSheet({ store, host, folder, approval, place, down, close }: {
  store: Store; host: string; folder: string; approval: ApprovalItem; place?: string | undefined; down: boolean;
  close: () => void;
}) {
  const reading = useSignal<GuardedChangeReading | null>(null);
  const loaded = useSignal(false);
  const busy = useSignal(false);
  const asking = useSignal(false);
  const note = useSignal("");
  const refusal = useSignal<string | null>(null);
  useEffect(() => {
    let current = true;
    // An archive request has nothing to read: its session is the thing.
    if (approval.kind === "archive") {
      loaded.value = true;
      return;
    }
    reading.value = null;
    loaded.value = false;
    store.readApproval(host, folder, approval).then(
      (read) => { if (current) reading.value = read; },
      (error) => { if (current) refusal.value = describe(error); },
    ).finally(() => { if (current) loaded.value = true; });
    return () => { current = false; };
  }, [host, folder, approval.kind, approval.key, approval.digest]);
  // The version answered is the one read, so a change since is refused, not approved.
  const send = async (action: ApprovalAction) => {
    busy.value = true;
    refusal.value = null;
    const digest = approval.kind === "archive" ? undefined : reading.value?.digest ?? approval.digest;
    try {
      await store.answerApproval(host, folder, approval, action, digest,
        action === "requestChanges" ? note.value.trim() : undefined);
      close();
    } catch (error) {
      refusal.value = describe(error);
    } finally {
      busy.value = false;
    }
  };
  const held = busy.value || down || (approval.kind !== "archive" && !reading.value && approval.digest !== undefined);
  const offers = (action: ApprovalAction) => approval.actions.includes(action);
  return (
    <Modal label={approval.title} close={close}>
      <form method="dialog" class="sheet-body approval-sheet" onSubmit={(e) => e.preventDefault()}>
        <div class="approval-head">
          <ApprovalMark />
          <div>
            <h2>{approval.title}</h2>
            <p class="quiet small">{[kindWords[approval.kind], place].filter(Boolean).join(" · ")}</p>
          </div>
        </div>
        <p>{approval.line}</p>
        <p class="quiet">{explanations[approval.kind]}</p>
        {reading.value ? <>
          <p class="quiet small">{reading.value.path}</p>
          <div class="approval-lines"><Lines lines={readingLines(reading.value)} /></div>
        </> : !loaded.value && <p class="quiet">Reading…</p>}
        {asking.value && (
          <textarea rows={3} aria-label="Changes to ask for" placeholder={notePlaceholder} value={note.value}
            onInput={(e) => (note.value = (e.currentTarget as HTMLTextAreaElement).value)} />
        )}
        {refusal.value && <p class="sheet-note failure" role="alert">{refusal.value}</p>}
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <span class="spacer" />
          {asking.value ? (
            <button type="button" class="prominent" disabled={held || !note.value.trim()}
              onClick={() => void send("requestChanges")}>{sendNoteLabel}</button>
          ) : <>
            {offers("requestChanges") && (
              <button type="button" disabled={held} onClick={() => (asking.value = true)}>
                {actionWord(approval.kind, "requestChanges")}
              </button>
            )}
            {offers("deny") && (
              <button type="button" disabled={held} onClick={() => void send("deny")}>{actionWord(approval.kind, "deny")}</button>
            )}
            {offers("approve") && (
              <button type="button" class="prominent" disabled={held} onClick={() => void send("approve")}>
                {actionWord(approval.kind, "approve")}
              </button>
            )}
          </>}
        </div>
      </form>
    </Modal>
  );
}
