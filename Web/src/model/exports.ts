// Export… and Import Agents… (#1001), as the window's and the Remote's: an agent or a project's
// agents as a .tar.gz the browser downloads, and one brought back, archived, into a project
// (#2389). The host makes and reads the file; the page carries it in parts.
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

/** AgentsExportTransfer.imported: what an import did, in a line; `project` is where they went. */
export function importedWords(r: BackupRestoreResult, project?: string): string {
  const count = (r.restored === 1 ? "1 agent" : `${r.restored} agents`) + (project ? ` into ${project}` : "");
  if (r.skipped === 0) return r.restored === 0 ? "There were no agents to import." : `Imported ${count}, archived.`;
  const skipped = r.skipped === 1 ? "1 was skipped" : `${r.skipped} were skipped`;
  const lead = r.restored === 0 ? "Imported no agents" : `Imported ${count}, archived`;
  return `${lead}. ${skipped}: already here, or deleted here.`;
}

function fromBase64(text: string): Uint8Array {
  const binary = atob(text);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

/** The export made and read, part by part, as the bytes of one file and its name. */
export async function readExport(call: Call, host: string, request: AgentsExportRequest)
  : Promise<{ name: string; agents: number; parts: Uint8Array[] }> {
  const made = await call<AgentsExport>("agents/export", request, host);
  const parts: Uint8Array[] = [];
  let offset = 0;
  for (;;) {
    const params: SendReadRequest = { id: made.file.id, offset };
    const part = await call<{ data: string; end: boolean }>("agents/exportRead", params, host);
    const bytes = fromBase64(part.data);
    parts.push(bytes);
    offset += bytes.length;
    if (part.end || bytes.length === 0) break;
  }
  return { name: made.name, agents: made.agents, parts };
}

/** Sends `bytes` in parts, then imports them, into the project at `folder` when one is given. */
export async function sendImport(call: Call, host: string, bytes: Uint8Array, upload: string,
  folder?: string): Promise<BackupRestoreResult> {
  for (let offset = 0; offset < bytes.length; offset += importPartSize) {
    const part = bytes.subarray(offset, offset + importPartSize);
    const params: ReceiveUploadRequest = { upload: upload as UUID, offset, data: base64(part) as ReceiveUploadRequest["data"] };
    await call("agents/importUpload", params, host);
  }
  const params: AgentsImportRequest = { upload: upload as UUID, ...(folder ? { folder: folder as NonNullable<AgentsImportRequest["folder"]> } : {}) };
  return await call<BackupRestoreResult>("agents/import", params, host);
}

/** Export…: the file, downloaded under the name the host gave it. */
export async function downloadExport(call: Call, host: string, request: AgentsExportRequest): Promise<void> {
  const { name, parts } = await readExport(call, host, request);
  const url = URL.createObjectURL(new Blob(parts as BlobPart[], { type: "application/gzip" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/** Import Agents…: a file chosen, sent and imported into a project; `done` hears what it did. */
export function chooseImport(call: Call, host: string, into: { folder: string; name: string },
  done: (words: string) => void, failed: (error: unknown) => void): void {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = ".gz,.tgz,application/gzip";
  input.onchange = () => {
    const file = input.files?.[0];
    if (!file) return;
    void file.arrayBuffer()
      .then((buffer) => sendImport(call, host, new Uint8Array(buffer), crypto.randomUUID().toUpperCase(), into.folder))
      .then((result) => done(importedWords(result, into.name)), failed);
  };
  input.click();
}

/** The store's link as a `Call`. */
function callOf(store: Store): Call {
  return <R>(method: string, params: unknown, host: string) =>
    store.link.call(method as Method, params as never, host) as Promise<R>;
}

/** Export… from a menu: a failure is said as any other. */
export function exportFromMenu(store: Store, host: string, request: AgentsExportRequest): void {
  void downloadExport(callOf(store), host, request).catch((error: unknown) => store.say(describe(error)));
}

/** Import Agents… from a project's menu: on its machine, into that project; what it did is said. */
export function importFromMenu(store: Store, host: string, into: { folder: string; name: string }): void {
  chooseImport(callOf(store), host, into, (words) => store.say(words), (error) => store.say(describe(error)));
}
