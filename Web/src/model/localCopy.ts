// The page's local copy (#4790; spec 4777-fast, "the copy is a cache, never the record"): each
// machine's row, folders and lean session records (the live ones and the archived page last
// shown), and the end of the last 20 transcripts opened, in IndexedDB beside the keys. The page
// draws it at once, marked as from this device, and the host's answer always wins. A forget
// deletes the database, so the copy goes with the keys (direction.md, customer data).
import { effect } from "@preact/signals";
import type { Agent, ControlMachine, FolderSummary, TranscriptPage, TurnsPage } from "../protocol/generated";
import { formatRef } from "../protocol/ref";
import { openAgentsDatabase } from "../wire/keys";
import type { Store } from "./store";

/** The most the copy holds, as the Remote's (spec 4777-fast). */
export const copyCap = 50 * 1024 * 1024;
/** The transcripts kept: the last ones opened. */
export const transcriptsKept = 20;
/** A transcript's entries kept: its end, as one `agents/transcript` page (store.ts `turnPage`). */
export const entriesKept = 200;
/** A change is written this long after the last one, so a busy chat writes once a second at most. */
export const writeAfter = 1_000;

/** One machine: its row, folders and session records. */
export interface MachineCopy {
  kind: "machine";
  ref: string;
  host: ControlMachine;
  folders?: FolderSummary[];
  agents: Agent[];
  at: number;
}

/** One transcript's end: its finished turns and its last page of entries. */
export interface TranscriptCopy {
  kind: "transcript";
  ref: string;
  host: string;
  session: string;
  turns: TurnsPage;
  page: TranscriptPage;
  at: number;
}

export type CopyRecord = MachineCopy | TranscriptCopy;

/** What the copy knows of each record without reading it, kept as one record of its own. */
export interface CopyIndexRow {
  ref: string;
  kind: CopyRecord["kind"];
  at: number;
  bytes: number;
}

/** A machine's ref (#4727). */
export function machineRef(host: string): string {
  return formatRef({ provider: "agents", type: "machine", topic: "", id: host });
}

/**
 * A session's ref (#4727). The topic, the folder's origin, is left out: the session's id is
 * unique without it, and a session of a folder with no origin has none.
 */
export function sessionRef(session: string): string {
  return formatRef({ provider: "agents", type: "session", topic: "", id: session });
}

/**
 * The refs to drop so the copy keeps its caps: transcripts past the newest `kept`, then the
 * oldest transcript while the whole is over `cap`. Machines are never dropped: all of them are
 * well under a megabyte.
 */
export function overCaps(rows: readonly CopyIndexRow[], cap = copyCap, kept = transcriptsKept): string[] {
  const transcripts = rows.filter((r) => r.kind === "transcript").sort((a, b) => b.at - a.at);
  const drop = transcripts.slice(kept);
  let total = rows.reduce((sum, r) => sum + r.bytes, 0) - drop.reduce((sum, r) => sum + r.bytes, 0);
  for (let i = kept - 1; i >= 0 && total > cap; i--) {
    const oldest = transcripts[i];
    if (!oldest || drop.includes(oldest)) continue;
    drop.push(oldest);
    total -= oldest.bytes;
  }
  return drop.map((r) => r.ref);
}

/** Where the copy lives: IndexedDB on the page, memory in the tests. */
export interface CopyStore {
  get(ref: string): Promise<unknown>;
  /** Puts and deletes in one transaction. */
  write(put: ReadonlyArray<[string, unknown]>, drop: readonly string[]): Promise<void>;
}

const indexKey = "@index";

/** The store `copy` in the database `agents` (wire/keys.ts). */
export class IndexedCopyStore implements CopyStore {
  async get(ref: string): Promise<unknown> {
    const db = await openAgentsDatabase();
    try {
      return await new Promise((resolve, reject) => {
        const request = db.transaction("copy", "readonly").objectStore("copy").get(ref);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
    } finally {
      db.close();
    }
  }

  async write(put: ReadonlyArray<[string, unknown]>, drop: readonly string[]): Promise<void> {
    const db = await openAgentsDatabase();
    try {
      await new Promise<void>((resolve, reject) => {
        const tx = db.transaction("copy", "readwrite");
        const store = tx.objectStore("copy");
        for (const ref of drop) store.delete(ref);
        for (const [ref, value] of put) store.put(value, ref);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      });
    } finally {
      db.close();
    }
  }
}

/** For the tests: the same contract, in memory. */
export class MemoryCopyStore implements CopyStore {
  readonly held = new Map<string, unknown>();
  async get(ref: string): Promise<unknown> {
    return structuredClone(this.held.get(ref));
  }
  async write(put: ReadonlyArray<[string, unknown]>, drop: readonly string[]): Promise<void> {
    for (const ref of drop) this.held.delete(ref);
    for (const [ref, value] of put) this.held.set(ref, structuredClone(value));
  }
}

/**
 * The copy: its index in memory, its records in the store. Every failure is swallowed: a copy
 * that cannot be read or written is no copy, and the page fetches as it did before.
 */
export class LocalCopy {
  private index = new Map<string, CopyIndexRow>();
  private queue: Promise<void> = Promise.resolve();
  /** Off while the page is not signed in: a write then would make the database again. */
  writing = false;

  constructor(readonly store: CopyStore = new IndexedCopyStore(), readonly cap = copyCap) {}

  /** The index, then every machine it names. */
  async machines(): Promise<MachineCopy[]> {
    try {
      const rows = ((await this.store.get(indexKey)) as CopyIndexRow[] | undefined) ?? [];
      this.index = new Map(rows.map((r) => [r.ref, r]));
      const machines = await Promise.all(rows.filter((r) => r.kind === "machine").map((r) => this.store.get(r.ref)));
      return machines.filter((m): m is MachineCopy => (m as MachineCopy | undefined)?.kind === "machine");
    } catch {
      return [];
    }
  }

  async transcript(session: string): Promise<TranscriptCopy | null> {
    try {
      const got = (await this.store.get(sessionRef(session))) as TranscriptCopy | undefined;
      return got?.kind === "transcript" ? got : null;
    } catch {
      return null;
    }
  }

  /**
   * Puts records and keeps the caps, one write after another. With `machines`, the hosts the
   * page lists now, every other machine in the copy goes.
   */
  put(records: readonly CopyRecord[], machines?: readonly string[]): Promise<void> {
    const listed = machines && new Set(machines.map(machineRef));
    const drop = listed ? [...this.index.values()].filter((r) => r.kind === "machine" && !listed.has(r.ref)).map((r) => r.ref) : [];
    if (!this.writing || (records.length === 0 && drop.length === 0)) return this.queue;
    for (const ref of drop) this.index.delete(ref);
    for (const record of records) {
      this.index.set(record.ref, { ref: record.ref, kind: record.kind, at: record.at, bytes: JSON.stringify(record).length * 2 });
    }
    for (const ref of overCaps([...this.index.values()], this.cap)) {
      this.index.delete(ref);
      drop.push(ref);
    }
    const put: Array<[string, unknown]> = [...records.map((r): [string, unknown] => [r.ref, r]), [indexKey, [...this.index.values()]]];
    this.queue = this.queue.then(() => (this.writing ? this.store.write(put, drop) : undefined)).catch(() => undefined);
    return this.queue;
  }

  /** At sign-out: nothing more is written, and what is in memory goes. The database itself goes with the keys. */
  forget(): void {
    this.writing = false;
    this.index.clear();
  }
}

/** The end of the open transcript, as a page: the last `entriesKept` entries held. */
export function transcriptEnd(store: Store, host: string, session: string, at: number): TranscriptCopy {
  const entries = store.entries.peek();
  const cut = Math.max(0, entries.length - entriesKept);
  const kept = entries.slice(cut);
  const firstIndex = store.firstEntryIndex.peek() + cut;
  return {
    kind: "transcript", ref: sessionRef(session), host, session, at,
    turns: { turns: store.turns.peek(), firstTurn: store.firstTurn.peek(), openStart: store.openTurnStart.peek(),
      ...(store.firstPrompt.peek() === null ? {} : { firstPrompt: store.firstPrompt.peek()! }) },
    page: { firstIndex, total: firstIndex + kept.length, entries: kept },
  };
}

/**
 * Draws the copy into the store at once, and keeps it as the hosts answer: a machine when its
 * row, folders or sessions change, the open transcript when its entries or turns do, each a
 * second after the last change. Only what a host said is written, never what came from the copy.
 */
export function startLocalCopy(store: Store, copy: LocalCopy, now: () => number = Date.now): () => void {
  void copy.machines().then((machines) => store.drawCopy(machines));
  const written = new Map<string, { host: ControlMachine; folders?: FolderSummary[] | undefined; agents?: Agent[] | undefined }>();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const later = (write: () => void) => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => { timer = undefined; write(); }, writeAfter);
  };
  const writeMachines = () => {
    const records: MachineCopy[] = [];
    const hosts = store.hosts.peek();
    const fromDevice = store.fromDevice.peek();
    for (const host of hosts) {
      if (fromDevice.has(host.id)) continue;
      const folders = store.folders.peek()[host.id];
      const agents = store.agents.peek()[host.id];
      const was = written.get(host.id);
      if (was && was.host === host && was.folders === folders && was.agents === agents) continue;
      written.set(host.id, { host, folders, agents });
      records.push({ kind: "machine", ref: machineRef(host.id), host, ...(folders ? { folders } : {}), agents: agents ?? [], at: now() });
    }
    for (const id of [...written.keys()]) if (!hosts.some((h) => h.id === id)) written.delete(id);
    void copy.put(records, hosts.map((h) => h.id));
  };
  const stopMachines = effect(() => {
    void store.hosts.value;
    void store.folders.value;
    void store.agents.value;
    void store.fromDevice.value;
    if (copy.writing) later(writeMachines);
  });
  let transcriptTimer: ReturnType<typeof setTimeout> | undefined;
  const stopTranscript = effect(() => {
    const watching = store.watching.value;
    void store.entries.value;
    void store.turns.value;
    const source = store.transcriptSource.value;
    if (transcriptTimer) clearTimeout(transcriptTimer);
    if (!watching || source !== "host" || !copy.writing) return;
    transcriptTimer = setTimeout(() => {
      const still = store.watching.peek();
      if (still?.host !== watching.host || still.session !== watching.session || store.transcriptSource.peek() !== "host") return;
      void copy.put([transcriptEnd(store, watching.host, watching.session, now())]);
    }, writeAfter);
  });
  // A chat opened draws its copy until its host's page comes.
  const stopDraw = effect(() => {
    const watching = store.watching.value;
    if (!watching) return;
    void copy.transcript(watching.session).then((got) => { if (got) store.drawTranscriptCopy(got); });
  });
  return () => {
    stopMachines();
    stopTranscript();
    stopDraw();
    if (timer) clearTimeout(timer);
    if (transcriptTimer) clearTimeout(transcriptTimer);
  };
}
