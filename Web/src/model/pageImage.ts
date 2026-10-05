// A picture in a Markdown page, and how close a picture in Files is shown (#258).
//
// Swift draws a picture from beside the document and from nowhere else (ImageStamps,
// MarkdownText): no address on the network, and no path that climbs out of the
// document's folder. The bytes come from `files/read`, and the page's CSP already
// allows an image made from a blob.
import type { FileReading } from "../protocol/generated";

const mediaTypes: Record<string, string> = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
  heic: "image/heic", bmp: "image/bmp", tif: "image/tiff", tiff: "image/tiff", svg: "image/svg+xml", ico: "image/x-icon",
};

/** The type a picture file is drawn as, or null when the name is not a picture. */
export function mediaType(path: string): string | null {
  const name = path.split("/").filter(Boolean).pop() ?? "";
  const dot = name.lastIndexOf(".");
  const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
  return mediaTypes[ext] ?? null;
}

export function bytesOf(base64: string): Uint8Array {
  const raw = atob(base64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

/** What `files/read` handed back, when it is a picture the page can draw. */
export function pictureFromReading(path: string, reading: FileReading): { bytes: Uint8Array; type: string } | null {
  const type = mediaType(path);
  if (!type) return null;
  if (reading.kind === "image") return { bytes: bytesOf(reading.bytes), type };
  // SVG arrives as text. Drawn as an image from its bytes, scripts never run.
  if (reading.kind === "text" && type === "image/svg+xml") return { bytes: new TextEncoder().encode(reading.text), type };
  return null;
}

const withScheme = /^[a-z][a-z0-9+.-]*:/i;

function fileBase(path: string): string {
  return "file://" + path.split("/").map((part) => encodeURIComponent(part)).join("/");
}

function inside(path: string, folder: string): boolean {
  if (folder === "/") return path.startsWith("/") && path !== "/";
  return path.startsWith(folder + "/");
}

/**
 * Where a Markdown image lives, or null when it must stay a placeholder.
 *
 * `documentPath` is the page's own file. A relative name resolves beside it, the way
 * `ImageStamps.url` does, and only a picture inside that folder is returned.
 */
export function pageImagePath(source: string, documentPath: string): string | null {
  const raw = source.trim();
  if (!raw || !documentPath.startsWith("/") || /[\u0000-\u001f\\]/.test(raw)) return null;
  const lower = raw.toLowerCase();
  if (withScheme.test(raw) && !lower.startsWith("file:")) return null;
  const folder = documentPath.slice(0, documentPath.lastIndexOf("/")) || "/";
  let url: URL;
  try {
    url = lower.startsWith("file:") ? new URL(raw) : new URL(raw, fileBase(documentPath));
  } catch {
    return null;
  }
  if (url.protocol !== "file:" || url.hostname !== "" || url.search || url.hash) return null;
  let path: string;
  try {
    path = decodeURIComponent(url.pathname);
  } catch {
    return null;
  }
  // A `%2e%2e` survives the URL parser and only becomes `..` once decoded. Settle it
  // again, or a picture could name a file outside the document's folder.
  if (/[\u0000-\u001f\\]/.test(path)) return null;
  path = settle(path) ?? "";
  if (!path || !inside(path, folder) || !mediaType(path)) return null;
  return path;
}

/** `/a/../b` as `/b`, or null when it climbs above the root. */
function settle(path: string): string | null {
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return null;
      parts.pop();
      continue;
    }
    parts.push(part);
  }
  return "/" + parts.join("/");
}

/** Most a picture is blown up past its own size. Past this a screenshot is squares. */
export const zoomMost = 8;
/** Each Zoom in or Zoom out, as the window's buttons step. */
export const zoomStep = 1.5;

/**
 * The magnification that shows the whole picture, never more than its own size:
 * a small icon blown up to fill the pane is not a preview of the icon.
 */
export function fitMagnification(imageW: number, imageH: number, roomW: number, roomH: number): number {
  if (imageW <= 0 || imageH <= 0 || roomW <= 0 || roomH <= 0) return 1;
  return Math.min(1, roomW / imageW, roomH / imageH);
}

export function clampMagnification(level: number, fit: number): number {
  const min = fit;
  const max = Math.max(zoomMost, fit);
  return Math.min(max, Math.max(min, level));
}

export function stepMagnification(level: number, fit: number, direction: 1 | -1): number {
  return clampMagnification(level * (direction > 0 ? zoomStep : 1 / zoomStep), fit);
}

/**
 * A double-click goes between fitted and actual size. A picture smaller than the pane
 * is already at its own size when fitted, so it goes twice as close instead.
 */
export function magnificationAfterDoubleClick(level: number, fit: number): number {
  const fitted = Math.abs(level - fit) < 0.0001;
  if (!fitted) return fit;
  return clampMagnification(fit < 1 ? 1 : 2, fit);
}
