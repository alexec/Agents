// The page's local copy (#4790; spec 4777-fast, "the copy is a cache, never the record"): each
// machine's row, folders and lean session records (the live ones and the archived page last
// shown), and the end of the last 20 transcripts opened, in IndexedDB beside the keys. The page
// draws it at once, marked as from this device, and the host's answer always wins. A forget
// deletes the database, so the copy goes with the keys (direction.md, customer data).
import { effect } from "@preact/signals";
import type { Agent, ControlMachine, FolderSummary, ListRevision, TranscriptPage, TurnsPage } from "../protocol/generated";
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
  /** Where `agents` are in the host's order of changes (#4794): a launch asks only for what changed since. */
  point?: ListRevision;
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

/** What each Work entry holds (#4930), with how many of it are kept, the newest first; the pictures also to `imageCap`. */
export const workKept = { list: 30, item: 50, plan: 50, features: 10, timeline: 20, boards: 10, image: 2000 } as const;
export type WorkGroup = keyof typeof workKept;

/** One of Work's last answers (#4930), kept by what was asked: a cache, never the record. */
export interface WorkCopy {
  kind: "work";
  ref: string;
  group: WorkGroup;
  value: unknown;
  at: number;
}

export type CopyRecord = MachineCopy | TranscriptCopy | WorkCopy;

/** What the copy knows of each record without reading it, kept as one record of its own. */
export interface CopyIndexRow {
  ref: string;
  kind: CopyRecord["kind"];
  /** A Work entry's group (#4930). */
  group?: WorkGroup | undefined;
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

/** A Work entry's ref (#4727, #4930): its group, and what was asked. */
export function workRef(group: WorkGroup, asked: string): string {
  return formatRef({ provider: "agents", type: "work", topic: group, id: asked });
}

/**
 * The refs to drop so the copy keeps its caps: transcripts past the newest `kept`, then the
 * oldest transcript while the whole is over `cap`. Machines are never dropped: all of them are
 * well under a megabyte.
 */
export function overCaps(rows: readonly CopyIndexRow[], cap = copyCap, kept = transcriptsKept, imageCap = cap / 4): string[] {
  const newest = (a: CopyIndexRow, b: CopyIndexRow) => b.at - a.at;
  const transcripts = rows.filter((r) => r.kind === "transcript").sort(newest);
  const drop = transcripts.slice(kept);
  // Each Work group to its count, and the pictures to their own cap (#4930).
  const work: CopyIndexRow[] = [];
  for (const group of Object.keys(workKept) as WorkGroup[]) {
    const held = rows.filter((r) => r.kind === "work" && r.group === group).sort(newest);
    let bytes = held.reduce((sum, r) => sum + r.bytes, 0);
    while (held.length > workKept[group] || (group === "image" && held.length > 0 && bytes > imageCap)) {
      const oldest = held.pop()!;
      bytes -= oldest.bytes;
      drop.push(oldest);
    }
    work.push(...held);
  }
  let total = rows.reduce((sum, r) => sum + r.bytes, 0) - drop.reduce((sum, r) => sum + r.bytes, 0);
  // Over the cap, the oldest Work entry goes first, then the oldest transcript.
  work.sort(newest);
  while (total > cap && work.length > 0) {
    const oldest = work.pop()!;
    drop.push(oldest);
    total -= oldest.bytes;
  }
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
      this.index.set(record.ref, { ref: record.ref, kind: record.kind, ...(record.kind === "work" ? { group: record.group } : {}), at: record.at,
        bytes: JSON.stringify(record).length * 2 });
    }
    for (const ref of overCaps([...this.index.values()], this.cap)) {
      this.index.delete(ref);
      drop.push(ref);
    }
    const put: Array<[string, unknown]> = [...records.map((r): [string, unknown] => [r.ref, r]), [indexKey, [...this.index.values()]]];
    this.queue = this.queue.then(() => (this.writing ? this.store.write(put, drop) : undefined)).catch(() => undefined);
    return this.queue;
  }

  /** Work's last answer for what was asked (#4930); undefined with none. */
  async work<T>(group: WorkGroup, asked: string): Promise<T | undefined> {
    try {
      const got = (await this.store.get(workRef(group, asked))) as WorkCopy | undefined;
      return got?.kind === "work" && got.group === group ? got.value as T : undefined;
    } catch {
      return undefined;
    }
  }

  /** A host's answer, kept for the next open (#4930). Only a host's answers are kept, never what came from the copy. */
  keepWork(group: WorkGroup, asked: string, value: unknown, at = Date.now()): Promise<void> {
    return this.put([{ kind: "work", ref: workRef(group, asked), group, value, at }]);
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
    // The host's count, not this page's (#4794): a reconnect resumes from it, and an entry heard but
    // never written would count past it.
    page: { firstIndex, total: store.chatEnd() ?? firstIndex + kept.length, entries: kept },
  };
}

/**
 * Draws the copy into the store at once, and keeps it as the hosts answer: a machine when its
 * row, folders or sessions change, the open transcript when its entries or turns do, each a
 * second after the last change. Only what a host said is written, never what came from the copy.
 */
export function startLocalCopy(store: Store, copy: LocalCopy, now: () => number = Date.now): () => void {
  void copy.machines().then((machines) => store.drawCopy(machines));
  // A chat with nothing held reads its copy before asking its host, so it can resume from it (#4794).
  store.readCopy = (session) => copy.transcript(session);
  const written = new Map<string, { host: ControlMachine; folders?: FolderSummary[] | undefined; agents?: Agent[] | undefined;
    point?: ListRevision | undefined }>();
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
      const point = store.listPoint(host.id);
      const was = written.get(host.id);
      if (was && was.host === host && was.folders === folders && was.agents === agents && was.point === point) continue;
      written.set(host.id, { host, folders, agents, point });
      records.push({ kind: "machine", ref: machineRef(host.id), host, ...(folders ? { folders } : {}), agents: agents ?? [],
        ...(point ? { point } : {}), at: now() });
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
    store.readCopy = undefined;
    stopMachines();
    stopTranscript();
    stopDraw();
    if (timer) clearTimeout(timer);
    if (transcriptTimer) clearTimeout(transcriptTimer);
  };
}

/** The page's copy, for Work's pages (#4930): set at start, none in the tests that do not set it. */
let pageCopy: LocalCopy | undefined;
export function setWorkCopy(copy: LocalCopy | undefined): void { pageCopy = copy; }

/** Work's last answer this device kept for what was asked (#4930). */
export function keptWork<T>(group: WorkGroup, asked: string): Promise<T | undefined> {
  return pageCopy ? pageCopy.work<T>(group, asked) : Promise.resolve(undefined);
}

/** A host's answer to a Work page, kept (#4930). */
export function keepWork(group: WorkGroup, asked: string, value: unknown): void {
  void pageCopy?.keepWork(group, asked, value);
}

/** A forge's picture (#4930): from this device's copy when it holds it, as a picture does not change at its URL; else
 * read, and kept. */
export async function keptPicture<T>(url: string, read: (url: string) => Promise<T>): Promise<T> {
  const kept = await keptWork<T>("image", url);
  if (kept !== undefined) return kept;
  const got = await read(url);
  keepWork("image", url, got);
  return got;
}
