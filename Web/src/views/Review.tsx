// One change waiting for an OK, on a page of its own in the chat's place (#1472), as the window's and
// the Remote's ReviewPage (Shared/UI/ReviewPage.swift): a workflow, a guarded `.agents` file, an MCP
// server's entry or a plugin's files. The header says what it is, where, who changed it and since
// when; then what the answers do; then the whole change, which the page scrolls; and the host's
// answers in a bar that stays at the foot. The version answered is the one read: a change since is
// refused, and the refusal is said here. Answered, it goes to the session that made the change, or
// to the folder.
import { useSignal } from "@preact/signals";
import { useEffect, useMemo } from "preact/hooks";
import type { ApprovalAction, GuardedChangeReading } from "../protocol/generated";
import type { Store } from "../model/store";
import { actionWord, approvalID, explanations, kindWords, notePlaceholder, sendNoteLabel } from "../model/approvals";
import { shortAgo } from "../model/activity";
import { describe } from "../model/errors";
import { hunkRows, type FileDiffRow } from "../model/fileDiff";
import { fromWireDate } from "../protocol/dates";
import { go } from "../route";
import { BackToList } from "./BackToList";
import { ApprovalMark } from "./Approval";
import { FileDiff, type DiffLayout } from "./FileDiff";

/** At most this many lines come from the host (GuardedDiffLine.limit). */
export const readingLimit = 400;

/** The page draws the old file beside the new from this width, as the window does from 820 points. */
const wideFrom = "(min-width: 1100px)";
const layoutKey = "agents.reviewDiffLayout";

/** A reading's lines as one hunk of the whole file, numbered from line 1 on both sides. */
export function readingRows(reading: GuardedChangeReading): FileDiffRow[] {
  return hunkRows([{ oldStart: 1, newStart: 1,
    lines: reading.lines.map((line) => ({ kind: line.kind === "same" ? "context" : line.kind, text: line.text })) }]);
}

/** How many lines were added and removed: the card's "+N −M". */
export function readingCounts(reading: GuardedChangeReading): { added: number; removed: number } {
  let added = 0, removed = 0;
  for (const line of reading.lines) {
    if (line.kind === "added") added++;
    else if (line.kind === "removed") removed++;
  }
  return { added, removed };
}

export function ReviewPage({ store, host, folder, folderName, id, down }: {
  store: Store; host: string; folder: string; folderName: string; id: string; down: boolean;
}) {
  const summary = (store.folders.value[host] ?? []).find((p) => p.folder.folder === folder);
  const approval = summary?.approvals?.find((a) => approvalID(a) === id);
  const reading = useSignal<GuardedChangeReading | null>(null);
  const loaded = useSignal(false);
  const busy = useSignal(false);
  const asking = useSignal(false);
  const note = useSignal("");
  const refusal = useSignal<string | null>(null);
  const wide = useSignal(globalThis.matchMedia?.(wideFrom).matches ?? true);
  const layout = useSignal<DiffLayout>(globalThis.localStorage?.getItem(layoutKey) === "sideBySide" ? "sideBySide" : "unified");
  useEffect(() => {
    const query = globalThis.matchMedia?.(wideFrom);
    if (!query) return;
    const changed = () => (wide.value = query.matches);
    query.addEventListener("change", changed);
    return () => query.removeEventListener("change", changed);
  }, []);
  useEffect(() => {
    if (!approval) return;
    let current = true;
    reading.value = null;
    loaded.value = false;
    store.readApproval(host, folder, approval).then(
      (read) => { if (current) reading.value = read; },
      (error) => { if (current) refusal.value = describe(error); },
    ).finally(() => { if (current) loaded.value = true; });
    return () => { current = false; };
  }, [host, folder, approval?.kind, approval?.key, approval?.digest]);
  const rows = useMemo(() => (reading.value ? readingRows(reading.value) : []), [reading.value]);
  if (!approval) {
    return (
      <section class="chat empty review-page" aria-label="Review">
        <header class="column-head"><BackToList /><h1>Review</h1></header>
        <span class="glyph" aria-hidden="true">✓</span>
        <h2>Nothing waits for an OK here</h2>
        <p>The change was answered, or it is no longer there.</p>
      </section>
    );
  }
  const since = approval.since === undefined ? undefined : fromWireDate(approval.since);
  const agentID = approval.agentID as string | undefined;
  const leave = () => go(agentID && store.agent(host, agentID) ? { host, folder: folder, session: agentID } : { host, folder: folder });
  // The version answered is the one read, so a change since is refused, not approved.
  const send = async (action: ApprovalAction) => {
    busy.value = true;
    refusal.value = null;
    try {
      await store.answerApproval(host, folder, approval, action, reading.value?.digest ?? approval.digest,
        action === "requestChanges" ? note.value.trim() : undefined);
      leave();
    } catch (error) {
      refusal.value = describe(error);
    } finally {
      busy.value = false;
    }
  };
  const held = busy.value || down || (!reading.value && approval.digest !== undefined);
  const offers = (action: ApprovalAction) => approval.actions.includes(action);
  const counts = reading.value ? readingCounts(reading.value) : undefined;
  const choose = (next: DiffLayout) => {
    layout.value = next;
    globalThis.localStorage?.setItem(layoutKey, next);
  };
  return (
    <section class="chat review-page" aria-label={`Review ${approval.title}`}>
      <header class="column-head"><BackToList /><h1>{approval.title}</h1></header>
      <div class="scroll">
        <div class="review-body">
          <div class="review-head">
            <ApprovalMark />
            <div>
              <h2>{approval.title}</h2>
              <p class="quiet small">
                {[kindWords[approval.kind], folderName].join(" · ")}
                {since && <> · <time dateTime={since.toISOString()} title={since.toLocaleString()}>{shortAgo(since)}</time></>}
              </p>
              <p>
                {approval.line}
                {agentID && <> <button type="button" class="link" onClick={() => go({ host, folder: folder, session: agentID })}>Open Session</button></>}
              </p>
            </div>
          </div>
          <p class="quiet">{explanations[approval.kind]}</p>
          {reading.value ? <>
            <div class="review-diff-head">
              <span class="quiet small path">{reading.value.path}</span>
              {counts && <span class="quiet small counts" aria-label={`${counts.added} lines added, ${counts.removed} removed`}>
                +{counts.added} −{counts.removed}</span>}
              <span class="spacer" />
              {wide.value && (
                <span class="tabs" role="tablist" aria-label="Show">
                  <button type="button" role="tab" class={layout.value === "unified" ? "on" : ""} aria-selected={layout.value === "unified"} onClick={() => choose("unified")}>Unified</button>
                  <button type="button" role="tab" class={layout.value === "sideBySide" ? "on" : ""} aria-selected={layout.value === "sideBySide"} onClick={() => choose("sideBySide")}>Side by Side</button>
                </span>
              )}
            </div>
            {rows.length ? <FileDiff rows={rows} layout={wide.value ? layout.value : "unified"} /> : <p class="quiet">No lines changed.</p>}
            {reading.value.lines.length >= readingLimit && (
              <p class="quiet small">The change is longer than {readingLimit} lines. The rest is not shown here; open {reading.value.path} in the folder to read it all.</p>
            )}
          </> : !loaded.value ? <p class="quiet">Reading…</p> : <p class="quiet">The change could not be read.</p>}
        </div>
      </div>
      <footer class="review-bar">
        {refusal.value && <p class="sheet-note failure" role="alert">{refusal.value}</p>}
        {asking.value && (
          <textarea rows={3} aria-label="Changes to ask for" placeholder={notePlaceholder} value={note.value}
            onInput={(e) => (note.value = (e.currentTarget as HTMLTextAreaElement).value)} />
        )}
        <div class="sheet-actions">
          <span class="spacer" />
          {asking.value ? <>
            <button type="button" onClick={() => (asking.value = false)}>Cancel</button>
            <button type="button" class="prominent" disabled={held || !note.value.trim()}
              onClick={() => void send("requestChanges")}>{sendNoteLabel}</button>
          </> : <>
            {offers("requestChanges") && (
              <button type="button" disabled={held} onClick={() => (asking.value = true)}>
                {actionWord(approval.kind, "requestChanges")}…
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
      </footer>
    </section>
  );
}
