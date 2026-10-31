// Export… and Import Agents… (#1001), as the window's and the Remote's: an agent or a folder's
// agents as a .tar.gz the browser downloads, and one brought back, archived, into a folder
// (#2389). The host makes and reads the file; the page carries it in parts, with a busy sheet
// and Cancel while it does (#2437).
import type { AgentsExport, AgentsExportRequest, AgentsImportRequest, BackupRestoreResult, ReceiveUploadRequest, SendReadRequest, UUID }
  from "../protocol/generated";
import type { Method } from "../protocol/methods";
import { base64 } from "../wire/bytes";
import { describe } from "./errors";
import type { Store } from "./store";

/** A part of an import: 1 MB of file, about 1.4 MB of base64 in one message. */
export const importPartSize = 1 << 20;

/** What the page needs of the link: one call to a host. */
export type Call = <R>(method: string, params: unknown, host: string) => Promise<R>;

/** AgentsExportTransfer.imported: what an import did, in a line; `folder` is where they went. */
export function importedWords(r: BackupRestoreResult, folder?: string): string {
  const count = (r.restored === 1 ? "1 agent" : `${r.restored} agents`) + (folder ? ` into ${folder}` : "");
  if (r.skipped === 0) return r.restored === 0 ? "There were no agents to import." : `Imported ${count}, archived.`;
  const skipped = r.skipped === 1 ? "1 was skipped" : `${r.skipped} were skipped`;
  const lead = r.restored === 0 ? "Imported no agents" : `Imported ${count}, archived`;
  return `${lead}. ${skipped}: already here, or deleted here.`;
}

/** The busy sheet (#2437): what is going on, how far (null: nothing to count), and Cancel. */
export interface ExportImportBusy { line: string; fraction: number | null; cancel: () => void }

/** How far a read or a send is, and whether Cancel was pressed: checked between parts. */
export interface Watch { progress?: (done: number, whole: number) => void; cancelled?: () => boolean }

/** Thrown between parts once Cancel is pressed; said to nobody. */
export class Cancelled extends Error {
  constructor() { super("Cancelled"); }
}

function check(watch?: Watch): void {
  if (watch?.cancelled?.()) throw new Cancelled();
}

/** AgentsExportTransfer.exporting: "Exporting 12 agents…", or before the host has said how many. */
export function exportingWords(agents: number | null): string {
  if (agents === null) return "Making the export…";
  return agents === 1 ? "Exporting 1 agent…" : `Exporting ${agents} agents…`;
}

/** AgentsExportTransfer.importing: while the parts are sent, then while the host brings them back. */
export function importingWords(sent: boolean): string {
  return sent ? "Importing the agents…" : "Sending the export…";
}

function fromBase64(text: string): Uint8Array {
  const binary = atob(text);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

/** The export made and read, part by part, as the bytes of one file and its name. */
export async function readExport(call: Call, host: string, request: AgentsExportRequest, watch?: Watch,
  made?: (agents: number) => void): Promise<{ name: string; agents: number; parts: Uint8Array[] }> {
  const export_ = await call<AgentsExport>("agents/export", request, host);
  made?.(export_.agents);
  const parts: Uint8Array[] = [];
  let offset = 0;
  for (;;) {
    check(watch);
    const params: SendReadRequest = { id: export_.file.id, offset };
    const part = await call<{ data: string; end: boolean }>("agents/exportRead", params, host);
    const bytes = fromBase64(part.data);
    parts.push(bytes);
    offset += bytes.length;
    watch?.progress?.(offset, Math.max(export_.file.size, offset));
    if (part.end || bytes.length === 0) break;
  }
  return { name: export_.name, agents: export_.agents, parts };
}

/** Sends `bytes` in parts, then imports them, into the folder at `folder` when one is given. */
export async function sendImport(call: Call, host: string, bytes: Uint8Array, upload: string,
  folder?: string, watch?: Watch): Promise<BackupRestoreResult> {
  for (let offset = 0; offset < bytes.length; offset += importPartSize) {
    check(watch);
    const part = bytes.subarray(offset, offset + importPartSize);
    const params: ReceiveUploadRequest = { upload: upload as UUID, offset, data: base64(part) as ReceiveUploadRequest["data"] };
    await call("agents/importUpload", params, host);
    watch?.progress?.(offset + part.length, bytes.length);
  }
  check(watch);
  const params: AgentsImportRequest = { upload: upload as UUID, ...(folder ? { folder: folder as NonNullable<AgentsImportRequest["folder"]> } : {}) };
  return await call<BackupRestoreResult>("agents/import", params, host);
}

/** Export…: the file, downloaded under the name the host gave it. */
export async function downloadExport(call: Call, host: string, request: AgentsExportRequest, watch?: Watch,
  made?: (agents: number) => void): Promise<void> {
  const { name, parts } = await readExport(call, host, request, watch, made);
  const url = URL.createObjectURL(new Blob(parts as BlobPart[], { type: "application/gzip" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/** Import Agents…: a file chosen, sent and imported into a folder; `done` hears what it did. */
export function chooseImport(call: Call, host: string, into: { folder: string; name: string },
  done: (words: string) => void, failed: (error: unknown) => void, watch?: Watch, chosen?: () => void): void {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = ".gz,.tgz,application/gzip";
  input.onchange = () => {
    const file = input.files?.[0];
    if (!file) return;
    chosen?.();
    void file.arrayBuffer()
      .then((buffer) => sendImport(call, host, new Uint8Array(buffer), crypto.randomUUID().toUpperCase(), into.folder, watch))
      .then((result) => done(importedWords(result, into.name)), failed);
  };
  input.click();
}

/** The store's link as a `Call`. */
function callOf(store: Store): Call {
  return <R>(method: string, params: unknown, host: string) =>
    store.link.call(method as Method, params as never, host) as Promise<R>;
}

/** The busy sheet for one transfer, on the store while it runs; Cancel stops it between parts. */
function busy(store: Store, line: string): { watch: Watch; set: (line: string) => void; end: () => void } {
  let cancelled = false;
  const sheet = { line, fraction: null as number | null, cancel: () => { cancelled = true; store.exportImport.value = null; } };
  store.exportImport.value = sheet;
  const show = () => { if (!cancelled) store.exportImport.value = { ...sheet }; };
  return {
    watch: {
      progress: (done, whole) => { sheet.fraction = whole > 0 ? done / whole : null; show(); },
      cancelled: () => cancelled,
    },
    set: (words) => { sheet.line = words; sheet.fraction = null; show(); },
    end: () => { if (!cancelled) store.exportImport.value = null; },
  };
}

/** A failure is said as any other; a cancel is not. */
function sayFailure(store: Store, error: unknown): void {
  if (!(error instanceof Cancelled)) store.say(describe(error));
}

/** Export… from a menu: one at a time, with the busy sheet up until the file is downloaded. */
export function exportFromMenu(store: Store, host: string, request: AgentsExportRequest): void {
  if (store.exportImport.value) return;
  const b = busy(store, exportingWords(null));
  void downloadExport(callOf(store), host, request, b.watch, (agents) => b.set(exportingWords(agents)))
    .catch((error: unknown) => sayFailure(store, error))
    .finally(b.end);
}

/** Import Agents… from a folder's menu: on its machine, into that folder; what it did is said. */
export function importFromMenu(store: Store, host: string, into: { folder: string; name: string }): void {
  if (store.exportImport.value) return;
  let b: ReturnType<typeof busy> | null = null;
  const watch: Watch = {
    progress: (done, whole) => {
      b?.watch.progress?.(done, whole);
      if (done >= whole) b?.set(importingWords(true));
    },
    cancelled: () => b?.watch.cancelled?.() ?? false,
  };
  chooseImport(callOf(store), host, into,
    (words) => { b?.end(); store.say(words); },
    (error) => { b?.end(); sayFailure(store, error); },
    watch, () => { b = busy(store, importingWords(false)); });
}
