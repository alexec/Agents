// A project's drop box (#231): files put into `<project>/.agents/dropbox/`, where a workflow on
// `dropbox.file_added` picks them up. The window drops files onto a project's row; the page does
// the same, and has Put Files in Drop Box… in the row's menu for a folder inside it. From a
// browser, as from a phone, a file crosses the relayed link in one record (PhoneAttachment).
import type { DropboxPutRequest } from "../protocol/generated";
import { base64 } from "../wire/bytes";
import { limit, sizeWords } from "./attachments";

/** Why this file can't go, or null when it can. */
export function dropboxRefusal(name: string, size: number): string | null {
  if (name.startsWith(".")) return `${name} starts with a dot, so the drop box would pass it over.`;
  if (size > limit) {
    return `From a browser, a drop box file can be 900 KB, and ${name} is ${sizeWords(size)}. Copy it into .agents/dropbox/ on its host instead.`;
  }
  return null;
}

/** A folder inside the drop box as typed, its slashes and spaces at either end let go; null for its top. */
export function dropboxSubfolder(typed: string): string | null {
  const trimmed = typed.trim().replace(/^\/+|\/+$/g, "").trim();
  return trimmed === "" ? null : trimmed;
}

/** The call for one file's bytes. */
export function dropboxRequest(folder: string, subfolder: string, name: string, bytes: Uint8Array): DropboxPutRequest {
  const inside = dropboxSubfolder(subfolder);
  return {
    folder: folder as DropboxPutRequest["folder"],
    ...(inside === null ? {} : { subfolder: inside }),
    name,
    data: base64(bytes) as DropboxPutRequest["data"],
  };
}
