// A change to one of the app's own files in a folder's `.agents`, made outside the app (#502), as
// the question every client asks (#531; Shared/UI/Chat/GuardedChangeCard.swift): who made it, how many
// lines changed, Review… for the whole change on its own page (#1472), and Keep or Undo for a quick answer. Asked over the prompt of the agent that made it, or on the
// folder's page when no agent did. Until then the host goes on with the copy last approved. A workflow
// waiting for an OK is asked the same way, by its file's path (#569).
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { GuardedChange, GuardedChangeReading } from "../protocol/generated";
import type { Store } from "../model/store";
import { go } from "../route";
import { readingCounts } from "./Review";

/** Every guarded change asked here: in `session`, or of the folder `folder` when there is none. */
export function GuardedChangeCards({ store, host, where, down = false }: {
  store: Store; host: string; where: { session: string } | { folder: string };
  /** Its host is down: the answers are held until it is back. */
  down?: boolean;
}) {
  const asked = store.guardedChanges(host, where);
  if (!asked.length) return null;
  return (
    <div class="cards">
      {asked.map(({ folder, change }) => (
        <GuardedChangeCard key={`${folder}|${change.path}`} store={store} host={host} folder={folder} change={change} down={down} />
      ))}
    </div>
  );
}

/** A workflow waiting for an OK (#569), as GuardedChange.isWorkflow has it: its id, or undefined. */
function workflowID(path: string): string | undefined {
  return /^\.agents\/workflows\/([^/]+)\.md$/.exec(path)?.[1];
}

/** GuardedChange.approvalID: the item in the folder's approvals that asks the same thing, whose Review page opens by it. */
export function guardedApprovalID(change: GuardedChange): string {
  const id = workflowID(change.path);
  return id === undefined ? `file:${change.path}` : `workflow:${id}`;
}

/** Who changed what, as GuardedChange.headline has it. */
export function guardedHeadline(change: GuardedChange): string {
  const what = change.digest === undefined ? `removed ${change.path}` : `changed ${change.path}`;
  const names = change.changedBy;
  if (names.length) {
    const who = names.length === 1 ? names[0]! : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]!}`;
    return `${who} ${what}`;
  }
  if (change.byGit) return `A merge or pull ${what}`;
  return `Something outside the app ${what}`;
}

export function GuardedChangeCard({ store, host, folder, change, down }: {
  store: Store; host: string; folder: string; change: GuardedChange; down: boolean;
}) {
  const reading = useSignal<GuardedChangeReading | null>(null);
  const busy = useSignal(false);
  useEffect(() => {
    let current = true;
    reading.value = null;
    void store.readGuardedChange(host, folder, change).then((read) => { if (current) reading.value = read; });
    return () => { current = false; };
  }, [host, folder, change.path, change.digest]);
  const answer = (keep: boolean) => {
    const read = reading.value;
    if (!read) return;
    busy.value = true;
    void store.settleGuardedChange(host, folder, read, keep).finally(() => (busy.value = false));
  };
  const held = !reading.value || busy.value || down;
  const counts = reading.value ? readingCounts(reading.value) : undefined;
  return (
    <div class="card guarded-change" role="alert" aria-label={`Keep the change to ${change.path}?`}>
      <p class="strong">{guardedHeadline(change)}</p>
      <p class="guarded-answers">
        {counts ? <span class="quiet small counts" aria-label={`${counts.added} lines added, ${counts.removed} removed`}>
          +{counts.added} −{counts.removed}</span> : <span class="quiet small">Reading the change…</span>}
        <span class="spacer" />
        <button onClick={() => go({ host, folder: folder, review: guardedApprovalID(change) })}>Review…</button>
        <button disabled={held} onClick={() => answer(false)}>Undo</button>
        <button class="prominent" disabled={held} onClick={() => answer(true)}>Keep</button>
      </p>
    </div>
  );
}
