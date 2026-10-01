// What a browser may attach to a prompt, and in what form: the phone's rules (PhoneAttachment,
// Model/PhoneAttachment.swift), because a file in a browser is, like one on a phone, nowhere the
// host can open. Everything goes by value: a picture shrunk to a JPEG, text as its contents;
// anything else is refused in one sentence before it is sent. The same 900 KB in all.
import type { ACPPromptCapabilities, Attachment, ContentBlock, UUID } from "../protocol/generated";
import { base64 } from "../wire/bytes";

/** A picture's longest side, once shrunk. */
export const longestEdge = 2048;
/** Everything attached by value to one prompt. */
export const limit = 900_000;

export type Made = { ok: Attachment } | { refused: string };

function newID(): UUID {
  return crypto.randomUUID().toUpperCase() as UUID;
}

/** A file read as text, or refused when it isn't text. `type` is the browser's MIME type. */
export function textAttachment(bytes: Uint8Array, name: string, type: string): Made {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return { refused: `${name} is not a picture or text, so it would have to be on the Mac to attach.` };
  }
  if (text.includes("\u0000")) {
    return { refused: `${name} is not a picture or text, so it would have to be on the Mac to attach.` };
  }
  const block: ContentBlock = { type: "resource", resource: { uri: `browser:${name}`, text, mimeType: type || "text/plain" } };
  return { ok: { id: newID(), block, displayName: name, byteCount: new TextEncoder().encode(text).length } };
}

/** A picture already shrunk, as a JPEG. */
export function pictureAttachment(jpeg: Uint8Array, name: string): Attachment {
  return { id: newID(), block: { type: "image", mimeType: "image/jpeg", data: base64(jpeg) }, displayName: name };
}

/** No bigger than `longestEdge` on its longest side, the right way up, as a JPEG. In a page only. */
export async function shrink(picture: Blob): Promise<Uint8Array | null> {
  try {
    const bitmap = await createImageBitmap(picture, { imageOrientation: "from-image" });
    const scale = Math.min(1, longestEdge / Math.max(bitmap.width, bitmap.height));
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext("2d");
    if (!context) return null;
    context.drawImage(bitmap, 0, 0, width, height);
    bitmap.close();
    const jpeg = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.8 });
    return new Uint8Array(await jpeg.arrayBuffer());
  } catch {
    return null;
  }
}

/** A dropped, pasted or picked file, made fit to send. */
export async function attach(file: File): Promise<Made> {
  const name = file.name || "Pasted picture";
  if (file.type.startsWith("image/")) {
    const jpeg = await shrink(file);
    return jpeg ? { ok: pictureAttachment(jpeg, name) } : { refused: `${name} could not be read as a picture.` };
  }
  return textAttachment(new Uint8Array(await file.arrayBuffer()), name, file.type);
}

function requirement(block: ContentBlock): "image" | "audio" | "embeddedContext" | null {
  switch (block.type) {
    case "image": return "image";
    case "audio": return "audio";
    case "resource": return "embeddedContext";
    default: return null;
  }
}

/** Why this runtime won't take it (Attachment.refusal and PhoneAttachment.refusal), or null. */
export function refusal(attachment: Attachment, capabilities: ACPPromptCapabilities | undefined): string | null {
  if (!capabilities) return null;
  const needs = requirement(attachment.block);
  if (needs === null || capabilities[needs] === true) return null;
  switch (needs) {
    case "image": return "This runtime does not take pictures";
    case "audio": return "This runtime does not take audio";
    case "embeddedContext": return "This runtime does not take file contents, so this can only be attached on the Mac";
  }
}

function inlineBytes(attachment: Attachment): number {
  const block = attachment.block;
  // Base64 is 4 characters for 3 bytes; the limit is on the bytes.
  if (block.type === "image" || block.type === "audio") return Math.floor((block.data.length * 3) / 4);
  if (block.type === "resource") {
    return new TextEncoder().encode(block.resource.text ?? "").length + Math.floor(((block.resource.blob ?? "").length * 3) / 4);
  }
  return 0;
}

/** "950 KB", "1.2 MB", as Foundation's file count style says them (1 KB = 1,000 bytes). */
export function sizeWords(bytes: number): string {
  if (bytes < 1_000) return `${bytes} bytes`;
  if (bytes < 1_000_000) return `${Math.round(bytes / 1_000)} KB`;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

/** Why these can't go together, or null when they can. */
export function totalRefusal(attachments: readonly Attachment[]): string | null {
  const total = attachments.reduce((sum, a) => sum + inlineBytes(a), 0);
  if (total <= limit) return null;
  return `From a browser, attachments can be 900 KB in all, and these are ${sizeWords(total)}. Remove one to send.`;
}
