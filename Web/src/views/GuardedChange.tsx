// A change to one of the app's own files in a project's `.agents`, made outside the app (#502), as
// the question every client asks (#531; Shared/UI/Chat/GuardedChangeCard.swift): who made it, what
// changed line by line, and Keep or Undo. Asked over the prompt of the agent that made it, or on the
// project's page when no agent did. Until then the host goes on with the copy last approved. A workflow
// waiting for an OK is asked the same way, by its file's path (#569).
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { DiffLine, GuardedChange, GuardedChangeReading } from "../protocol/generated";
import type { Store } from "../model/store";
import { Lines } from "./Changes";

/** Every guarded change asked here: in `session`, or of the project `folder` when there is none. */
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

/** What a file holds, in a person's words, as GuardedFile.holds has it. */
function holds(path: string): string {
  switch (path) {
    case ".agents/project.json": return "the helper limits and disk space lines";
    case ".agents/pins.json": return "the pins";
    default: return "the file";
  }
}

/** A workflow waiting for an OK (#569), as GuardedChange.isWorkflow has it. */
function isWorkflow(path: string): boolean {
  return /^\.agents\/workflows\/[^/]+\.md$/.test(path);
}

/** What Keep and Undo do, as GuardedChange.explanation has it. */
function explanation(path: string): string {
  if (isWorkflow(path)) {
    return "The workflow does not run until you choose. Keep approves the change; Undo puts back "
      + "the copy you last approved, or removes the file when you never approved one.";
  }
  return `The app goes on using ${holds(path)} as you last approved them until you choose. `
    + "Keep uses the change from now on; Undo puts the approved copy back in the file.";
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

function GuardedChangeCard({ store, host, folder, change, down }: {
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
  const lines: DiffLine[] = (reading.value?.lines ?? []).map((line) => ({
    kind: line.kind === "same" ? "context" : line.kind, text: line.text,
  }));
  const held = !reading.value || busy.value || down;
  return (
    <div class="card guarded-change" role="alert" aria-label={`Keep the change to ${change.path}?`}>
      <p class="strong">{guardedHeadline(change)}</p>
      <p class="quiet">{explanation(change.path)}</p>
      {reading.value ? <div class="question"><Lines lines={lines} /></div> : <p class="quiet">Reading the change…</p>}
      <p class="guarded-answers">
        <button disabled={held} onClick={() => answer(false)}>Undo</button>
        <button class="prominent" disabled={held} onClick={() => answer(true)}>Keep</button>
      </p>
    </div>
  );
}
